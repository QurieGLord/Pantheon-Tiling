namespace Gala {
    private class BspGroup : Object {
        public int workspace_index;
        public int monitor;
        public string key;
        public BspLayout layout = new BspLayout ();
        public weak Meta.Window? active_window = null;

        public BspGroup (int workspace_index, int monitor, string key) {
            this.workspace_index = workspace_index;
            this.monitor = monitor;
            this.key = key;
        }
    }

    private class BspReadyPlacement : Object {
        public Meta.Window window;
        public Mtk.Rectangle rect;

        public BspReadyPlacement (Meta.Window window, Mtk.Rectangle rect) {
            this.window = window;
            this.rect = rect;
        }
    }

    public class BspTree : Object {
        private const uint INITIAL_SYNC_DELAY_MS = 75;

        private Meta.Display display;
        private bool debug_enabled = Environment.get_variable ("GALA_BSP_DEBUG") == "1";
        private Gee.HashMap<string, BspGroup> groups = new Gee.HashMap<string, BspGroup> ();
        private Gee.HashMap<Meta.Window, BspGroup> window_groups = new Gee.HashMap<Meta.Window, BspGroup> ();
        private Gee.HashMap<Meta.Window, ulong> first_frame_handlers = new Gee.HashMap<Meta.Window, ulong> ();
        private Gee.HashMap<Meta.Window, uint> initial_sync_timeouts = new Gee.HashMap<Meta.Window, uint> ();
        private Gee.HashMap<Meta.Window, Meta.Window> interactive_swap_targets = new Gee.HashMap<Meta.Window, Meta.Window> ();
        private Gee.HashSet<Meta.Window> monitored_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> pending_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> interactive_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_with_first_frame = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_first_frame = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_initial_settle = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_map_reveal = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<string> dirty_groups = new Gee.HashSet<string> ();
        private Gee.ArrayList<BspReadyPlacement> ready_placements = new Gee.ArrayList<BspReadyPlacement> ();

        private bool rebuild_all = false;
        private uint flush_later_id = 0;
        private uint ready_reveal_later_id = 0;

        public BspTilingConfig config { get; private set; default = new BspTilingConfig (); }
        public signal void window_target_ready (Meta.Window window, Mtk.Rectangle rect);

        public BspTree (Meta.Display display) {
            this.display = display;

            display.window_created.connect (monitor_window);
            display.window_entered_monitor.connect (on_window_monitor_changed);
            display.window_left_monitor.connect (on_window_monitor_changed);
            display.workareas_changed.connect (queue_relayout_all_groups);
            display.notify["focus-window"].connect (update_active_window);
            display.grab_op_begin.connect (on_grab_op_begin);
            display.grab_op_end.connect (on_grab_op_end);

            unowned var workspace_manager = display.get_workspace_manager ();
            workspace_manager.workspace_added.connect (() => queue_full_rebuild ());
            workspace_manager.workspace_removed.connect (() => queue_full_rebuild ());
            workspace_manager.workspaces_reordered.connect (queue_full_rebuild);

            foreach (var window in display.list_all_windows ()) {
                monitor_existing_window (window);
            }
        }

        private void monitor_window (Meta.Window window) {
            monitor_window_internal (window, false);
        }

        private void monitor_existing_window (Meta.Window window) {
            monitor_window_internal (window, true);
        }

        private void monitor_window_internal (Meta.Window window, bool existing_window) {
            if (monitored_windows.contains (window)) {
                return;
            }

            monitored_windows.add (window);
            log_window_event (window, "monitor");

            window.notify.connect (on_window_notify);
            window.position_changed.connect (on_window_geometry_changed);
            window.size_changed.connect (on_window_geometry_changed);
            window.shown.connect (on_window_shown);
            window.workspace_changed.connect (on_window_workspace_changed);
            window.unmanaging.connect (on_window_unmanaging);
            window.unmanaged.connect (on_window_unmanaged);
            hook_window_actor (window);

            if (existing_window && window.showing_on_its_workspace ()) {
                windows_waiting_for_first_frame.remove (window);
                windows_with_first_frame.add (window);
                Idle.add (() => {
                    if (monitored_windows.contains (window)) {
                        queue_initial_sync (window);
                    }

                    return Source.REMOVE;
                });
            } else {
                windows_waiting_for_first_frame.add (window);
            }
        }

        private void on_window_shown (Meta.Window window) {
            log_window_event (window, "shown");
            hook_window_actor (window);
            windows_waiting_for_first_frame.add (window);

            Idle.add (() => {
                if (monitored_windows.contains (window)) {
                    queue_initial_sync (window);
                }

                return Source.REMOVE;
            });
        }

        private void unmonitor_window (Meta.Window window) {
            if (!monitored_windows.remove (window)) {
                return;
            }

            window.notify.disconnect (on_window_notify);
            window.position_changed.disconnect (on_window_geometry_changed);
            window.size_changed.disconnect (on_window_geometry_changed);
            window.shown.disconnect (on_window_shown);
            window.workspace_changed.disconnect (on_window_workspace_changed);
            window.unmanaging.disconnect (on_window_unmanaging);
            window.unmanaged.disconnect (on_window_unmanaged);

            pending_windows.remove (window);
            interactive_swap_targets.unset (window);
            interactive_windows.remove (window);
            windows_with_first_frame.remove (window);
            windows_waiting_for_first_frame.remove (window);
            windows_waiting_for_initial_settle.remove (window);
            windows_waiting_for_map_reveal.remove (window);
            remove_ready_placement (window);

            var handler_id = first_frame_handlers[window];
            if (handler_id != 0) {
                var actor = window.get_compositor_private () as Meta.WindowActor;
                if (actor != null && !actor.is_destroyed ()) {
                    actor.disconnect (handler_id);
                }

                first_frame_handlers.unset (window);
            }

            var timeout_id = initial_sync_timeouts[window];
            if (timeout_id != 0) {
                Source.remove (timeout_id);
                initial_sync_timeouts.unset (window);
            }
        }

        private void on_window_notify (Object object, ParamSpec pspec) {
            var window = (Meta.Window) object;

            switch (pspec.name) {
                case "fullscreen":
                case "maximized-horizontally":
                case "maximized-vertically":
                case "minimized":
                case "on-all-workspaces":
                case "window-type":
                case "above":
                    queue_sync_window (window);
                    break;
            }
        }

        private void on_window_workspace_changed (Meta.Window window) {
            queue_sync_window (window);
        }

        private void on_window_geometry_changed (Meta.Window window) {
            if (interactive_windows.contains (window)) {
                maybe_reorder_interactive_window (window);
                return;
            }

            var group = window_groups[window];
            if (group != null) {
                dirty_groups.add (group.key);
                schedule_flush ();
                return;
            }

            queue_sync_window (window);
        }

        private void on_window_unmanaging (Meta.Window window) {
            remove_window (window);
        }

        private void on_window_unmanaged (Meta.Window window) {
            remove_window (window);
            unmonitor_window (window);
        }

        private void on_window_monitor_changed (Meta.Display display, int monitor, Meta.Window window) {
            queue_sync_window (window);
        }

        private void on_window_first_frame (Meta.Window window) {
            log_window_event (window, "first-frame");
            windows_waiting_for_first_frame.remove (window);
            windows_with_first_frame.add (window);
            schedule_initial_sync_after_settle (window);
        }

        private void on_grab_op_begin (Meta.Window window, Meta.GrabOp op) {
            if (window.window_type != Meta.WindowType.NORMAL) {
                return;
            }

            interactive_windows.add (window);
            interactive_swap_targets.unset (window);
        }

        private void on_grab_op_end (Meta.Window window, Meta.GrabOp op) {
            if (!interactive_windows.remove (window)) {
                return;
            }

            interactive_swap_targets.unset (window);
            queue_sync_window (window);
        }

        private void update_active_window () {
            unowned var focus_window = display.focus_window;
            if (focus_window == null) {
                return;
            }

            var group = window_groups[focus_window];
            if (group != null) {
                group.active_window = focus_window;
            }
        }

        private void queue_sync_window (Meta.Window window) {
            if (!monitored_windows.contains (window)) {
                monitor_window (window);
            }

            if (windows_waiting_for_first_frame.contains (window)
                && !windows_with_first_frame.contains (window)) {
                log_window_event (window, "skip-queue/wait-first-frame");
                return;
            }

            if (windows_waiting_for_initial_settle.contains (window) && !window_groups.has_key (window)) {
                log_window_event (window, "skip-queue/wait-initial-settle");
                return;
            }

            log_window_event (window, "queue-sync");
            pending_windows.add (window);
            schedule_flush ();
        }

        private void queue_initial_sync (Meta.Window window) {
            if (windows_waiting_for_first_frame.contains (window)
                && !windows_with_first_frame.contains (window)) {
                log_window_event (window, "wait-first-frame");
                return;
            }

            if (windows_waiting_for_initial_settle.contains (window)) {
                log_window_event (window, "wait-initial-settle");
                return;
            }

            queue_sync_window (window);
        }

        private void schedule_initial_sync_after_settle (Meta.Window window) {
            if (windows_waiting_for_initial_settle.contains (window)) {
                return;
            }

            windows_waiting_for_initial_settle.add (window);
            log_window_event (window, "schedule-initial-sync");

            initial_sync_timeouts[window] = Timeout.add (INITIAL_SYNC_DELAY_MS, () => {
                initial_sync_timeouts.unset (window);

                if (!monitored_windows.contains (window)) {
                    return Source.REMOVE;
                }

                windows_waiting_for_initial_settle.remove (window);
                log_window_event (window, "initial-sync-ready");
                queue_sync_window (window);
                return Source.REMOVE;
            });
        }

        private void queue_full_rebuild () {
            rebuild_all = true;
            schedule_flush ();
        }

        private void queue_relayout_all_groups () {
            foreach (var group in groups.values) {
                mark_group_dirty (group.key, true);
            }

            schedule_flush ();
        }

        private void schedule_flush () {
            if (flush_later_id != 0) {
                return;
            }

            flush_later_id = display.get_compositor ().get_laters ().add (Meta.LaterType.BEFORE_REDRAW, () => {
                flush_later_id = 0;
                return flush_updates ();
            });
        }

        private bool flush_updates () {
            if (rebuild_all) {
                rebuild_all = false;
                rebuild_groups ();
            } else if (pending_windows.size > 0) {
                var windows = new Gee.ArrayList<Meta.Window> ();
                foreach (var window in pending_windows) {
                    windows.add (window);
                }

                pending_windows.clear ();

                foreach (var window in windows) {
                    sync_window (window);
                }
            }

            if (dirty_groups.size > 0) {
                var groups_to_layout = new Gee.ArrayList<string> ();
                foreach (var key in dirty_groups) {
                    groups_to_layout.add (key);
                }

                dirty_groups.clear ();

                foreach (var key in groups_to_layout) {
                    relayout_group (key);
                }
            }

            return Source.REMOVE;
        }

        private void rebuild_groups () {
            groups.clear ();
            window_groups.clear ();
            dirty_groups.clear ();

            var windows = new Gee.ArrayList<Meta.Window> ();
            foreach (var window in monitored_windows) {
                windows.add (window);
            }

            foreach (var window in windows) {
                sync_window (window);
            }
        }

        private void sync_window (Meta.Window window) {
            if (interactive_windows.contains (window)) {
                log_window_event (window, "skip-sync/interactive");
                return;
            }

            var current_group = window_groups[window];
            if (!is_tile_candidate (window)) {
                log_window_event (window, "skip-sync/not-candidate");
                if (current_group != null) {
                    remove_window (window);
                }

                return;
            }

            var target_key = get_group_key (window);
            if (target_key == null) {
                log_window_event (window, "skip-sync/no-group");
                if (current_group != null) {
                    remove_window (window);
                }

                return;
            }

            if (current_group != null && current_group.key == target_key) {
                log_window_event (window, "sync/dirty", target_key);
                mark_group_dirty (current_group.key, true);
                return;
            }

            if (current_group != null) {
                remove_window (window);
            }

            add_window (window, target_key);
        }

        private bool is_tile_candidate (Meta.Window window) {
            if (!is_potential_tile_candidate (window)) {
                return false;
            }

            if (windows_waiting_for_first_frame.contains (window)
                && !windows_with_first_frame.contains (window)) {
                return false;
            }

            if (windows_waiting_for_initial_settle.contains (window)) {
                return false;
            }

            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return false;
            }

            return window.get_workspace () != null && window.get_monitor () >= 0;
        }

        public bool should_skip_map_animation (Meta.Window window) {
            return is_potential_tile_candidate (window);
        }

        public void queue_map_reveal (Meta.Window window) {
            if (!is_potential_tile_candidate (window)) {
                return;
            }

            windows_waiting_for_map_reveal.add (window);
            log_window_event (window, "queue-map-reveal");
        }

        public void cancel_map_reveal (Meta.Window window) {
            windows_waiting_for_map_reveal.remove (window);
            remove_ready_placement (window);
        }

        public bool try_get_initial_frame_rect (Meta.Window window, out Mtk.Rectangle rect) {
            rect = { 0, 0, 0, 0 };

            if (!is_potential_tile_candidate (window)) {
                return false;
            }

            var target_key = get_group_key (window);
            if (target_key == null) {
                return false;
            }

            var workspace = display.get_workspace_manager ().get_workspace_by_index (window.get_workspace ().index ());
            if (workspace == null) {
                return false;
            }

            var work_area = workspace.get_work_area_for_monitor (window.get_monitor ());
            work_area = apply_outer_gap (work_area);
            if (work_area.width <= 0 || work_area.height <= 0) {
                return false;
            }

            var group = groups[target_key];
            if (group == null || group.layout.is_empty) {
                rect = work_area;
                return true;
            }

            var preview_layout = group.layout.copy ();
            Object? split_target = null;
            if (group.active_window != null
                && group.active_window != window
                && preview_layout.contains (group.active_window)) {
                split_target = group.active_window;
            }

            preview_layout.insert (window, split_target);
            var found = false;
            Mtk.Rectangle result_rect = { 0, 0, 0, 0 };
            preview_layout.foreach_leaf_rect (work_area, (tile, tile_rect) => {
                if (tile != window) {
                    return;
                }

                result_rect = apply_inner_gaps (tile_rect, work_area);
                found = true;
            });

            rect = result_rect;
            return found;
        }

        public bool should_skip_size_change_animation (Meta.Window window) {
            return window_groups.has_key (window)
                || windows_waiting_for_first_frame.contains (window)
                || windows_waiting_for_initial_settle.contains (window);
        }

        private bool is_potential_tile_candidate (Meta.Window window) {
            if (NotificationStack.is_notification (window)) {
                return false;
            }

            if (window.window_type != Meta.WindowType.NORMAL) {
                return false;
            }

            if (window.get_transient_for () != null) {
                return false;
            }

            if (!window.allows_move () || !window.allows_resize ()) {
                return false;
            }

            if (window.fullscreen || window.minimized || window.on_all_workspaces || window.is_above ()) {
                return false;
            }

            if (window.maximized_horizontally || window.maximized_vertically) {
                return false;
            }

            return true;
        }

        private void hook_window_actor (Meta.Window window) {
            if (first_frame_handlers.has_key (window)) {
                return;
            }

            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return;
            }

            first_frame_handlers[window] = actor.first_frame.connect (() => {
                on_window_first_frame (window);
            });
        }

        public void prepare_window_actor_for_target_rect (Meta.Window window, Mtk.Rectangle target_frame_rect) {
            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return;
            }

            var frame_rect = window.get_frame_rect ();
            var buffer_rect = window.get_buffer_rect ();
            var buffer_offset_x = buffer_rect.x - frame_rect.x;
            var buffer_offset_y = buffer_rect.y - frame_rect.y;
            var buffer_width_delta = buffer_rect.width - frame_rect.width;
            var buffer_height_delta = buffer_rect.height - frame_rect.height;
            var target_buffer_x = target_frame_rect.x + buffer_offset_x;
            var target_buffer_y = target_frame_rect.y + buffer_offset_y;
            var target_buffer_width = int.max (1, target_frame_rect.width + buffer_width_delta);
            var target_buffer_height = int.max (1, target_frame_rect.height + buffer_height_delta);
            var keep_hidden = windows_waiting_for_map_reveal.contains (window);

            if (keep_hidden) {
                actor.remove_all_transitions ();
                actor.set_scale (1.0f, 1.0f);
                actor.rotation_angle_x = 0.0f;
                actor.rotation_angle_y = 0.0f;
                actor.rotation_angle_z = 0.0f;
                actor.set_pivot_point (0.0f, 0.0f);
                actor.set_translation (0.0f, 0.0f, 0.0f);
            }

            actor.set_position (target_buffer_x, target_buffer_y);
            actor.set_size (target_buffer_width, target_buffer_height);
        }

        private string? get_group_key (Meta.Window window) {
            unowned var workspace = window.get_workspace ();
            if (workspace == null) {
                return null;
            }

            return build_key (workspace.index (), window.get_monitor ());
        }

        private string build_key (int workspace_index, int monitor) {
            return "%d:%d".printf (workspace_index, monitor);
        }

        private void mark_group_dirty (string key, bool settle = false) {
            dirty_groups.add (key);
        }

        private BspGroup get_or_create_group (Meta.Window window, string key) {
            var group = groups[key];
            if (group != null) {
                return group;
            }

            unowned var workspace = window.get_workspace ();
            group = new BspGroup (workspace.index (), window.get_monitor (), key);
            groups[key] = group;
            return group;
        }

        private void add_window (Meta.Window window, string key) {
            var group = get_or_create_group (window, key);

            Object? split_target = null;
            if (group.active_window != null
                && group.active_window != window
                && group.layout.contains (group.active_window)) {
                split_target = group.active_window;
            }

            group.layout.insert (window, split_target);
            group.active_window = window;
            window_groups[window] = group;
            log_window_event (window, "add", key);
            mark_group_dirty (group.key, true);
        }

        private void remove_window (Meta.Window window) {
            var group = window_groups[window];
            if (group == null) {
                return;
            }

            log_window_event (window, "remove", group.key);
            group.layout.remove (window);
            window_groups.unset (window);
            mark_group_dirty (group.key, true);
            schedule_flush ();

            if (group.active_window == window) {
                group.active_window = null;
            }

            if (group.layout.is_empty) {
                groups.unset (group.key);
                return;
            }

            if (group.active_window == null) {
                var replacement = group.layout.get_any_tile () as Meta.Window;
                group.active_window = replacement;
            }
        }

        private void relayout_group (string key) {
            var group = groups[key];
            if (group == null) {
                return;
            }

            var workspace = display.get_workspace_manager ().get_workspace_by_index (group.workspace_index);
            if (workspace == null) {
                groups.unset (group.key);
                return;
            }

            var work_area = workspace.get_work_area_for_monitor (group.monitor);
            work_area = apply_outer_gap (work_area);
            if (work_area.width <= 0 || work_area.height <= 0) {
                return;
            }

            var any_mismatch = false;
            group.layout.foreach_leaf_rect (work_area, (tile, rect) => {
                var window = tile as Meta.Window;
                if (window == null) {
                    return;
                }

                if (!window_groups.has_key (window)) {
                    return;
                }

                rect = apply_inner_gaps (rect, work_area);

                if (interactive_windows.contains (window)) {
                    return;
                }

                var frame_rect = window.get_frame_rect ();
                if (frame_rect.x == rect.x
                    && frame_rect.y == rect.y
                    && frame_rect.width == rect.width
                    && frame_rect.height == rect.height) {
                    if (windows_waiting_for_map_reveal.contains (window)) {
                        queue_window_target_ready (window, rect);
                    }

                    return;
                }

                any_mismatch = true;
                log_window_event (
                    window,
                    "move",
                    "%s (%d,%d %dx%d) -> (%d,%d %dx%d)".printf (
                        key,
                        frame_rect.x, frame_rect.y, frame_rect.width, frame_rect.height,
                        rect.x, rect.y, rect.width, rect.height
                    )
                );
                prepare_window_actor_for_target_rect (window, rect);
                window.move_resize_frame (false, rect.x, rect.y, rect.width, rect.height);

                if (windows_waiting_for_map_reveal.contains (window)) {
                    queue_window_target_ready (window, rect);
                }
            });

            if (!any_mismatch) {
                return;
            }
        }

        private void maybe_reorder_interactive_window (Meta.Window window) {
            if (!config.live_reorder_on_drag) {
                return;
            }

            var group = window_groups[window];
            if (group == null) {
                return;
            }

            var target = find_swap_target (group, window);
            if (target == null) {
                interactive_swap_targets.unset (window);
                return;
            }

            if (interactive_swap_targets[window] == target) {
                return;
            }

            if (!group.layout.swap (window, target)) {
                return;
            }

            interactive_swap_targets[window] = target;
            group.active_window = window;
            log_window_event (window, "swap", "%s <-> %s".printf (window.title ?? "(untitled)", target.title ?? "(untitled)"));
            mark_group_dirty (group.key, true);
            schedule_flush ();
        }

        private Meta.Window? find_swap_target (BspGroup group, Meta.Window window) {
            var frame_rect = window.get_frame_rect ();
            var best_target = null as Meta.Window;
            var best_overlap_area = 0;

            foreach (var tile in group.layout.get_tiles_in_order ()) {
                var other = tile as Meta.Window;
                if (other == null || other == window) {
                    continue;
                }

                var other_rect = other.get_frame_rect ();
                var overlap_left = int.max (frame_rect.x, other_rect.x);
                var overlap_top = int.max (frame_rect.y, other_rect.y);
                var overlap_right = int.min (frame_rect.x + frame_rect.width, other_rect.x + other_rect.width);
                var overlap_bottom = int.min (frame_rect.y + frame_rect.height, other_rect.y + other_rect.height);
                var overlap_width = overlap_right - overlap_left;
                var overlap_height = overlap_bottom - overlap_top;
                var overlap_area = overlap_width > 0 && overlap_height > 0 ? overlap_width * overlap_height : 0;

                if (overlap_area > best_overlap_area) {
                    best_overlap_area = overlap_area;
                    best_target = other;
                }
            }

            return best_target;
        }

        private Mtk.Rectangle apply_outer_gap (Mtk.Rectangle rect) {
            var gap = int.max (0, config.outer_gap);
            if (gap <= 0) {
                return rect;
            }

            var doubled_gap = gap * 2;
            if (rect.width <= doubled_gap || rect.height <= doubled_gap) {
                return rect;
            }

            rect.x += gap;
            rect.y += gap;
            rect.width -= doubled_gap;
            rect.height -= doubled_gap;
            return rect;
        }

        private Mtk.Rectangle apply_inner_gaps (Mtk.Rectangle rect, Mtk.Rectangle area) {
            var gap = int.max (0, config.inner_gap);
            if (gap <= 0) {
                return rect;
            }

            var half_gap = gap / 2;
            var other_half_gap = gap - half_gap;
            var left_gap = rect.x > area.x ? half_gap : 0;
            var right_gap = rect.x + rect.width < area.x + area.width ? other_half_gap : 0;
            var top_gap = rect.y > area.y ? half_gap : 0;
            var bottom_gap = rect.y + rect.height < area.y + area.height ? other_half_gap : 0;

            if (rect.width <= left_gap + right_gap || rect.height <= top_gap + bottom_gap) {
                return rect;
            }

            rect.x += left_gap;
            rect.y += top_gap;
            rect.width -= left_gap + right_gap;
            rect.height -= top_gap + bottom_gap;
            return rect;
        }

        private void queue_window_target_ready (Meta.Window window, Mtk.Rectangle rect) {
            remove_ready_placement (window);
            ready_placements.add (new BspReadyPlacement (window, rect));

            if (ready_reveal_later_id != 0) {
                return;
            }

            ready_reveal_later_id = display.get_compositor ().get_laters ().add (Meta.LaterType.BEFORE_REDRAW, () => {
                ready_reveal_later_id = 0;

                var placements = new Gee.ArrayList<BspReadyPlacement> ();
                foreach (var placement in ready_placements) {
                    placements.add (placement);
                }

                ready_placements.clear ();

                foreach (var placement in placements) {
                    if (!monitored_windows.contains (placement.window)) {
                        continue;
                    }

                    if (!windows_waiting_for_map_reveal.remove (placement.window)) {
                        continue;
                    }

                    log_window_event (
                        placement.window,
                        "target-ready",
                        "(%d,%d %dx%d)".printf (
                            placement.rect.x,
                            placement.rect.y,
                            placement.rect.width,
                            placement.rect.height
                        )
                    );
                    window_target_ready (placement.window, placement.rect);
                }

                return Source.REMOVE;
            });
        }

        private void remove_ready_placement (Meta.Window window) {
            for (int i = ready_placements.size - 1; i >= 0; i--) {
                if (ready_placements[i].window == window) {
                    ready_placements.remove_at (i);
                }
            }
        }

        private void log_window_event (Meta.Window window, string event, string extra = "") {
            if (!debug_enabled) {
                return;
            }

            var frame_rect = window.get_frame_rect ();
            var buffer_rect = window.get_buffer_rect ();
            var title = window.title ?? "(untitled)";
            var group = window_groups[window];
            var group_key = group != null ? group.key : "-";
            var suffix = extra != "" ? " %s".printf (extra) : "";
            var actor = window.get_compositor_private () as Meta.WindowActor;
            var actor_state = "";

            if (actor != null && !actor.is_destroyed ()) {
                float actor_x;
                float actor_y;
                float actor_width;
                float actor_height;
                actor.get_position (out actor_x, out actor_y);
                actor.get_size (out actor_width, out actor_height);
                actor_state = " buffer=(%d,%d %dx%d) actor=(%.1f,%.1f %.1fx%.1f scale=%.3f/%.3f trans=%.1f/%.1f opacity=%u)".printf (
                    buffer_rect.x,
                    buffer_rect.y,
                    buffer_rect.width,
                    buffer_rect.height,
                    actor_x,
                    actor_y,
                    actor_width,
                    actor_height,
                    actor.scale_x,
                    actor.scale_y,
                    actor.translation_x,
                    actor.translation_y,
                    actor.opacity
                );
            }

            message (
                "[BSP] %s title=\"%s\" group=%s monitor=%d frame=(%d,%d %dx%d)%s%s",
                event,
                title,
                group_key,
                window.get_monitor (),
                frame_rect.x,
                frame_rect.y,
                frame_rect.width,
                frame_rect.height,
                suffix,
                actor_state
            );
        }
    }
}
