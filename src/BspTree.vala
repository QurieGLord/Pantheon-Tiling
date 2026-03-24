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

    private class BspWindowPlacement : Object {
        public Meta.Window window;
        public Mtk.Rectangle rect;

        public BspWindowPlacement (Meta.Window window, Mtk.Rectangle rect) {
            this.window = window;
            this.rect = rect;
        }
    }

    public class BspTree : Object {
        private const uint INITIAL_SYNC_DELAY_MS = 75;
        private const int GAP_STEP = 4;

        private Meta.Display display;
        private GLib.Settings settings;
        private bool debug_enabled = Environment.get_variable ("GALA_BSP_DEBUG") == "1";
        private Gee.HashMap<string, BspGroup> groups = new Gee.HashMap<string, BspGroup> ();
        private Gee.HashMap<Meta.Window, BspGroup> window_groups = new Gee.HashMap<Meta.Window, BspGroup> ();
        private Gee.HashMap<Meta.Window, ulong> first_frame_handlers = new Gee.HashMap<Meta.Window, ulong> ();
        private Gee.HashMap<Meta.Window, uint> initial_sync_timeouts = new Gee.HashMap<Meta.Window, uint> ();
        private Gee.HashMap<Meta.Window, Meta.Window> interactive_swap_targets = new Gee.HashMap<Meta.Window, Meta.Window> ();
        private Gee.HashSet<Meta.Window> monitored_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> floating_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> pending_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> interactive_windows = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_with_first_frame = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_first_frame = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_initial_settle = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<Meta.Window> windows_waiting_for_map_reveal = new Gee.HashSet<Meta.Window> ();
        private Gee.HashSet<string> workspace_enabled = new Gee.HashSet<string> ();
        private Gee.HashSet<string> dirty_groups = new Gee.HashSet<string> ();
        private Gee.ArrayList<BspReadyPlacement> ready_placements = new Gee.ArrayList<BspReadyPlacement> ();

        private bool rebuild_all = false;
        private uint flush_later_id = 0;
        private uint ready_reveal_later_id = 0;

        public BspTilingConfig config { get; private set; default = new BspTilingConfig (); }
        public signal void window_target_ready (Meta.Window window, Mtk.Rectangle rect);

        public BspTree (Meta.Display display) {
            this.display = display;
            settings = new GLib.Settings ("io.elementary.desktop.wm.bsp");
            load_settings ();
            settings.changed.connect (on_settings_changed);

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
            floating_windows.remove (window);
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
                cancel_map_reveal (window);
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
            if (!should_manage_window (window)) {
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
            return should_manage_window (window);
        }

        public void queue_map_reveal (Meta.Window window) {
            if (!should_manage_window (window)) {
                return;
            }

            windows_waiting_for_map_reveal.add (window);
            log_window_event (window, "queue-map-reveal");
        }

        public void cancel_map_reveal (Meta.Window window) {
            if (windows_waiting_for_map_reveal.remove (window)) {
                restore_window_actor_visibility (window);
            }

            remove_ready_placement (window);
        }

        public bool try_get_initial_frame_rect (Meta.Window window, out Mtk.Rectangle rect) {
            rect = { 0, 0, 0, 0 };

            if (!should_manage_window (window)) {
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

        public bool is_enabled () {
            return config.enabled;
        }

        public string get_scope () {
            return config.scope;
        }

        public bool is_enabled_for_active_workspace () {
            return is_workspace_enabled (display.get_workspace_manager ().get_active_workspace ());
        }

        public int get_inner_gap () {
            return config.inner_gap;
        }

        public int get_outer_gap () {
            return config.outer_gap;
        }

        public bool toggle_enabled () {
            var new_enabled = !config.enabled;
            settings.set_string ("scope", "global");
            settings.set_boolean ("enabled", new_enabled);
            return new_enabled;
        }

        public bool toggle_active_workspace_enabled () {
            var workspace = display.get_workspace_manager ().get_active_workspace ();
            if (workspace == null) {
                return false;
            }

            var enabled_keys = get_workspace_enabled_keys ();
            if (config.scope != "workspace") {
                enabled_keys.clear ();

                if (config.enabled) {
                    var workspace_manager = display.get_workspace_manager ();
                    for (var i = 0; i < workspace_manager.get_n_workspaces (); i++) {
                        enabled_keys.add (i.to_string ());
                    }
                }

                settings.set_string ("scope", "workspace");
            }

            var key = workspace.index ().to_string ();
            var now_enabled = !enabled_keys.contains (key);
            if (now_enabled) {
                enabled_keys.add (key);
            } else {
                enabled_keys.remove (key);
            }

            settings.set_strv ("workspace-enabled", to_strv (enabled_keys));
            return now_enabled;
        }

        public int adjust_inner_gap (int delta) {
            var new_gap = int.max (0, config.inner_gap + delta);
            settings.set_int ("inner-gap", new_gap);
            return new_gap;
        }

        public int adjust_outer_gap (int delta) {
            var new_gap = int.max (0, config.outer_gap + delta);
            settings.set_int ("outer-gap", new_gap);
            return new_gap;
        }

        public bool increase_inner_gap () {
            adjust_inner_gap (GAP_STEP);
            return true;
        }

        public bool decrease_inner_gap () {
            adjust_inner_gap (-GAP_STEP);
            return true;
        }

        public bool increase_outer_gap () {
            adjust_outer_gap (GAP_STEP);
            return true;
        }

        public bool decrease_outer_gap () {
            adjust_outer_gap (-GAP_STEP);
            return true;
        }

        public bool is_window_floating (Meta.Window? window = null) {
            if (window == null) {
                window = display.focus_window;
            }

            return window != null && floating_windows.contains (window);
        }

        public bool is_window_tiled (Meta.Window? window = null) {
            if (window == null) {
                window = display.focus_window;
            }

            return window != null && window_groups.has_key (window);
        }

        public bool toggle_focused_window_floating () {
            return set_window_floating (display.focus_window, !is_window_floating ());
        }

        public bool set_window_floating (Meta.Window? window, bool floating) {
            if (window == null || !can_toggle_floating (window)) {
                return false;
            }

            if (floating) {
                if (!floating_windows.add (window)) {
                    return true;
                }

                cancel_map_reveal (window);
                remove_window (window);
                queue_sync_window (window);
                return true;
            }

            if (!floating_windows.remove (window)) {
                return false;
            }

            queue_sync_window (window);
            return true;
        }

        public bool focus_in_direction (Meta.MotionDirection direction) {
            var focus_window = display.focus_window;
            if (focus_window == null) {
                return false;
            }

            var group = window_groups[focus_window];
            if (group == null) {
                return false;
            }

            var target = find_directional_target (group, focus_window, direction);
            if (target == null) {
                return false;
            }

            target.activate (display.get_current_time ());
            return true;
        }

        public bool swap_focused_window_in_direction (Meta.MotionDirection direction) {
            return move_focused_window_in_direction (direction);
        }

        public bool move_focused_window_in_direction (Meta.MotionDirection direction) {
            var focus_window = display.focus_window;
            if (focus_window == null) {
                return false;
            }

            var group = window_groups[focus_window];
            if (group == null) {
                return false;
            }

            var target = find_directional_target (group, focus_window, direction);
            if (target == null || !group.layout.move (focus_window, target)) {
                return false;
            }

            group.active_window = focus_window;
            mark_group_dirty (group.key, true);
            schedule_flush ();
            focus_window.activate (display.get_current_time ());
            return true;
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

        private bool should_manage_window (Meta.Window window) {
            return is_potential_tile_candidate (window)
                && !floating_windows.contains (window)
                && is_workspace_enabled (window.get_workspace ());
        }

        private bool can_toggle_floating (Meta.Window window) {
            return window.window_type == Meta.WindowType.NORMAL
                && window.get_transient_for () == null
                && !NotificationStack.is_notification (window);
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

        private void restore_window_actor_visibility (Meta.Window window) {
            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return;
            }

            actor.opacity = 255U;
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

            if (!group.layout.move (window, target)) {
                return;
            }

            interactive_swap_targets[window] = target;
            group.active_window = window;
            log_window_event (window, "reorder", "%s -> %s".printf (window.title ?? "(untitled)", target.title ?? "(untitled)"));
            mark_group_dirty (group.key, true);
            schedule_flush ();
        }

        private Meta.Window? find_swap_target (BspGroup group, Meta.Window window) {
            var frame_rect = window.get_frame_rect ();
            var center_x = frame_rect.x + frame_rect.width / 2;
            var center_y = frame_rect.y + frame_rect.height / 2;

            foreach (var placement in collect_group_placements (group)) {
                if (placement.window == window) {
                    continue;
                }

                if (rect_contains_point (placement.rect, center_x, center_y)) {
                    return placement.window;
                }
            }

            return null;
        }

        private Meta.Window? find_directional_target (BspGroup group, Meta.Window window, Meta.MotionDirection direction) {
            var placements = collect_group_placements (group);
            BspWindowPlacement? current = null;

            foreach (var placement in placements) {
                if (placement.window == window) {
                    current = placement;
                    break;
                }
            }

            if (current == null) {
                return null;
            }

            BspWindowPlacement? closest = null;

            foreach (var placement in placements) {
                if (placement.window == window || !rects_intersect_in_direction (current.rect, placement.rect, direction)) {
                    continue;
                }

                if (closest == null || is_better_directional_match (current.rect, placement.rect, closest.rect, direction)) {
                    closest = placement;
                }
            }

            return closest != null ? closest.window : null;
        }

        private Gee.ArrayList<BspWindowPlacement> collect_group_placements (BspGroup group) {
            var placements = new Gee.ArrayList<BspWindowPlacement> ();
            var workspace = display.get_workspace_manager ().get_workspace_by_index (group.workspace_index);
            if (workspace == null) {
                return placements;
            }

            var work_area = apply_outer_gap (workspace.get_work_area_for_monitor (group.monitor));
            if (work_area.width <= 0 || work_area.height <= 0) {
                return placements;
            }

            group.layout.foreach_leaf_rect (work_area, (tile, rect) => {
                var window = tile as Meta.Window;
                if (window == null || !window_groups.has_key (window)) {
                    return;
                }

                placements.add (new BspWindowPlacement (window, apply_inner_gaps (rect, work_area)));
            });

            return placements;
        }

        private bool rects_intersect_in_direction (Mtk.Rectangle current, Mtk.Rectangle candidate, Meta.MotionDirection direction) {
            switch (direction) {
                case Meta.MotionDirection.LEFT:
                    return candidate.x <= current.x
                        && candidate.y + candidate.height > current.y
                        && candidate.y < current.y + current.height;
                case Meta.MotionDirection.RIGHT:
                    return candidate.x >= current.x
                        && candidate.y + candidate.height > current.y
                        && candidate.y < current.y + current.height;
                case Meta.MotionDirection.UP:
                    return candidate.y <= current.y
                        && candidate.x + candidate.width > current.x
                        && candidate.x < current.x + current.width;
                case Meta.MotionDirection.DOWN:
                    return candidate.y >= current.y
                        && candidate.x + candidate.width > current.x
                        && candidate.x < current.x + current.width;
                default:
                    return false;
            }
        }

        private bool is_better_directional_match (Mtk.Rectangle current, Mtk.Rectangle candidate, Mtk.Rectangle closest, Meta.MotionDirection direction) {
            switch (direction) {
                case Meta.MotionDirection.LEFT:
                    return candidate.x > closest.x;
                case Meta.MotionDirection.RIGHT:
                    return candidate.x < closest.x;
                case Meta.MotionDirection.UP:
                    return candidate.y > closest.y;
                case Meta.MotionDirection.DOWN:
                    return candidate.y < closest.y;
                default:
                    return false;
            }
        }

        private bool rect_contains_point (Mtk.Rectangle rect, int x, int y) {
            return x >= rect.x
                && x < rect.x + rect.width
                && y >= rect.y
                && y < rect.y + rect.height;
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

        private void load_settings () {
            config.enabled = settings.get_boolean ("enabled");
            config.scope = normalize_scope (settings.get_string ("scope"));
            config.inner_gap = int.max (0, settings.get_int ("inner-gap"));
            config.outer_gap = int.max (0, settings.get_int ("outer-gap"));
            config.border_width = int.max (0, settings.get_int ("border-width"));
            config.border_color = settings.get_string ("border-color");
            config.live_reorder_on_drag = settings.get_boolean ("live-reorder-on-drag");

            workspace_enabled.clear ();
            foreach (var key in settings.get_strv ("workspace-enabled")) {
                if (key != null && key != "") {
                    workspace_enabled.add (key);
                }
            }
        }

        private void on_settings_changed (string key) {
            var old_enabled = config.enabled;
            var old_scope = config.scope;
            var old_inner_gap = config.inner_gap;
            var old_outer_gap = config.outer_gap;
            var old_live_reorder = config.live_reorder_on_drag;

            load_settings ();

            switch (key) {
                case "enabled":
                case "scope":
                case "workspace-enabled":
                    if (old_enabled != config.enabled || old_scope != config.scope || key == "workspace-enabled") {
                        queue_full_rebuild ();
                    }
                    break;
                case "inner-gap":
                case "outer-gap":
                    if (old_inner_gap != config.inner_gap || old_outer_gap != config.outer_gap) {
                        queue_relayout_all_groups ();
                    }
                    break;
                case "live-reorder-on-drag":
                    if (old_live_reorder != config.live_reorder_on_drag) {
                        queue_relayout_all_groups ();
                    }
                    break;
                default:
                    break;
            }
        }

        private string normalize_scope (string scope) {
            return scope == "workspace" ? scope : "global";
        }

        private bool is_workspace_enabled (Meta.Workspace? workspace) {
            if (workspace == null) {
                return false;
            }

            if (config.scope == "workspace") {
                return workspace_enabled.contains (workspace.index ().to_string ());
            }

            return config.enabled;
        }

        private Gee.ArrayList<string> get_workspace_enabled_keys () {
            var keys = new Gee.ArrayList<string> ();
            foreach (var key in workspace_enabled) {
                keys.add (key);
            }

            keys.sort ((a, b) => {
                return int.parse (a) - int.parse (b);
            });
            return keys;
        }

        private string[] to_strv (Gee.List<string> values) {
            var strv = new string[values.size];
            for (int i = 0; i < values.size; i++) {
                strv[i] = values[i];
            }

            return strv;
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
