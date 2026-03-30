namespace Gala {
    [CCode (cname = "meta_window_is_always_on_all_workspaces", cheader_filename = "meta/window.h")]
    private extern bool meta_window_is_always_on_all_workspaces (Meta.Window window);

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

    private class BspPendingFrameRequest : Object {
        public Mtk.Rectangle old_rect;
        public Mtk.Rectangle rect;
        public uint timeout_id = 0;

        public BspPendingFrameRequest (Mtk.Rectangle old_rect, Mtk.Rectangle rect) {
            this.old_rect = old_rect;
            this.rect = rect;
        }
    }

    private class BspWindowMinimumSize : Object {
        public int width = 1;
        public int height = 1;
    }

    public class BspTree : Object {
        private const uint INITIAL_SYNC_DELAY_MS = 75;
        private const uint LAYOUT_REQUEST_TIMEOUT_MS = 160;
        private const int GAP_STEP = 4;
        private const int LAYOUT_SETTLE_TOLERANCE_PX = 4;

        private Meta.Display display;
        private GLib.Settings settings;
        private Gee.HashMap<string, BspGroup> groups = new Gee.HashMap<string, BspGroup> ();
        private Gee.HashMap<Meta.Window, BspGroup> window_groups = new Gee.HashMap<Meta.Window, BspGroup> ();
        private Gee.HashMap<Meta.Window, ulong> first_frame_handlers = new Gee.HashMap<Meta.Window, ulong> ();
        private Gee.HashMap<Meta.Window, uint> initial_sync_timeouts = new Gee.HashMap<Meta.Window, uint> ();
        private Gee.HashMap<Meta.Window, Meta.Window> interactive_swap_targets = new Gee.HashMap<Meta.Window, Meta.Window> ();
        private Gee.HashMap<Meta.Window, BspPendingFrameRequest> pending_frame_requests = new Gee.HashMap<Meta.Window, BspPendingFrameRequest> ();
        private Gee.HashMap<Meta.Window, BspWindowMinimumSize> observed_minimum_sizes = new Gee.HashMap<Meta.Window, BspWindowMinimumSize> ();
        private Gee.HashMap<Meta.Window, int> window_initial_monitor_overrides = new Gee.HashMap<Meta.Window, int> ();
        private Gee.HashMap<Meta.Window, int> window_monitor_hints = new Gee.HashMap<Meta.Window, int> ();
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
        public signal void window_relayout_requested (Meta.Window window, Mtk.Rectangle old_rect, Mtk.Rectangle new_rect);

        public BspTree (Meta.Display display) {
            this.display = display;
            settings = new GLib.Settings ("io.elementary.desktop.wm.bsp");
            load_settings ();
            settings.changed.connect (on_settings_changed);

            display.window_created.connect (monitor_window);
            display.window_entered_monitor.connect (on_window_entered_monitor);
            display.window_left_monitor.connect (on_window_left_monitor);
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

        private bool is_debug_enabled () {
            return Environment.get_variable ("GALA_BSP_DEBUG") == "1";
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

            if (!existing_window) {
                var initial_monitor = capture_preferred_initial_monitor (window);
                if (initial_monitor >= 0) {
                    window_initial_monitor_overrides[window] = initial_monitor;
                }
            }

            window.notify.connect (on_window_notify);
            window.position_changed.connect (on_window_position_changed);
            window.size_changed.connect (on_window_size_changed);
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

            if (window.get_client_type () == Meta.WindowClientType.X11
                && is_potential_tile_candidate (window)) {
                Idle.add (() => {
                    if (monitored_windows.contains (window)) {
                        mark_window_first_frame_ready (window, "shown-fallback");
                    }

                    return Source.REMOVE;
                });
            }

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
            window.position_changed.disconnect (on_window_position_changed);
            window.size_changed.disconnect (on_window_size_changed);
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
            window_initial_monitor_overrides.unset (window);
            window_monitor_hints.unset (window);
            remove_ready_placement (window);
            clear_pending_frame_request (window);
            observed_minimum_sizes.unset (window);

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
            log_window_event (window, "workspace-changed");
            queue_sync_window (window);
        }

        private void on_window_position_changed (Meta.Window window) {
            on_window_geometry_changed (window, "position-changed");
        }

        private void on_window_size_changed (Meta.Window window) {
            on_window_geometry_changed (window, "size-changed");
        }

        private void on_window_geometry_changed (Meta.Window window, string source) {
            log_window_event (window, source);

            var pending_request = pending_frame_requests[window];
            if (pending_request != null) {
                var frame_rect = window.get_frame_rect ();
                if (rect_matches_target_without_expansion (frame_rect, pending_request.rect)) {
                    clear_pending_frame_request (window);
                    return;
                }

                return;
            }

            if (interactive_windows.contains (window)) {
                maybe_reorder_interactive_window (window);
                return;
            }

            var group = window_groups[window];
            if (group != null) {
                var resolved_monitor = resolve_window_monitor (window);
                if (resolved_monitor >= 0 && resolved_monitor != group.monitor) {
                    queue_sync_window (window);
                    return;
                }

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

        private void on_window_entered_monitor (Meta.Display display, int monitor, Meta.Window window) {
            if (should_ignore_monitor_transition (window, monitor, "entered-monitor")) {
                return;
            }

            log_window_event (window, "entered-monitor", "event-monitor=%d".printf (monitor));
            if (monitor >= 0) {
                window_monitor_hints[window] = monitor;
                if (!window_groups.has_key (window)) {
                    window_initial_monitor_overrides[window] = monitor;
                }
            }

            queue_sync_window (window);
        }

        private void on_window_left_monitor (Meta.Display display, int monitor, Meta.Window window) {
            if (should_ignore_monitor_transition (window, monitor, "left-monitor")) {
                return;
            }

            log_window_event (window, "left-monitor", "event-monitor=%d".printf (monitor));
            if (window_monitor_hints.has_key (window) && window_monitor_hints[window] == monitor) {
                window_monitor_hints.unset (window);
            }

            queue_sync_window (window);
        }

        private bool should_ignore_monitor_transition (Meta.Window window, int monitor, string event) {
            if (!should_hold_window_monitor_to_group (window)) {
                return false;
            }

            log_window_event (window, "%s/ignored".printf (event), "event-monitor=%d".printf (monitor));
            return true;
        }

        private void on_window_first_frame (Meta.Window window) {
            mark_window_first_frame_ready (window, "signal");
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
                if (can_assume_first_frame_ready (window)) {
                    mark_window_first_frame_ready (
                        window,
                        windows_waiting_for_map_reveal.contains (window)
                            ? "deferred-map-fallback"
                            : "fallback"
                    );
                } else {
                    log_window_event (window, "skip-queue/wait-first-frame");
                    return;
                }
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
                if (can_assume_first_frame_ready (window)) {
                    mark_window_first_frame_ready (
                        window,
                        windows_waiting_for_map_reveal.contains (window)
                            ? "deferred-map-fallback"
                            : "fallback"
                    );
                } else {
                    log_window_event (window, "wait-first-frame");
                    return;
                }
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

            return window.get_workspace () != null && resolve_window_monitor (window) >= 0;
        }

        public bool should_skip_map_animation (Meta.Window window) {
            var reason = get_window_gate_rejection_reason (window, true);
            var should_skip = reason == "";
            log_window_gate ("should-skip-map-animation", window, should_skip, true, reason);
            return should_skip;
        }

        public void queue_map_reveal (Meta.Window window) {
            var reason = get_window_gate_rejection_reason (window, true);
            if (reason != "") {
                log_window_gate ("queue-map-reveal", window, false, true, reason);
                return;
            }

            windows_waiting_for_map_reveal.add (window);
            log_window_gate ("queue-map-reveal", window, true, true);
            log_window_event (window, "queue-map-reveal");
        }

        public void cancel_map_reveal (Meta.Window window) {
            if (windows_waiting_for_map_reveal.remove (window)) {
                restore_window_actor_visibility (window);
            }

            remove_ready_placement (window);
        }

        public void complete_map_reveal (Meta.Window window) {
            windows_waiting_for_map_reveal.remove (window);
        }

        public bool try_get_initial_frame_rect (Meta.Window window, out Mtk.Rectangle rect) {
            rect = { 0, 0, 0, 0 };

            var reason = get_window_gate_rejection_reason (window, true);
            if (reason != "") {
                log_window_gate ("try-get-initial-frame-rect", window, false, true, reason);
                return false;
            }

            var target_key = get_group_key (window, true);
            if (target_key == null) {
                log_window_event (window, "initial-frame/no-group-key");
                return false;
            }

            var monitor = resolve_window_monitor (window);
            if (monitor < 0) {
                log_window_event (window, "initial-frame/no-monitor");
                return false;
            }

            var workspace = resolve_effective_workspace (window);
            if (workspace == null) {
                log_window_event (window, "initial-frame/no-workspace");
                return false;
            }

            var work_area = workspace.get_work_area_for_monitor (monitor);
            work_area = apply_outer_gap (work_area);
            if (work_area.width <= 0 || work_area.height <= 0) {
                log_window_event (window, "initial-frame/empty-work-area");
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
            }, get_tile_min_size);

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

        public bool get_master_enabled () {
            return config.master_enabled;
        }

        public string get_master_side () {
            return config.master_side;
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
            return set_inner_gap (config.inner_gap + delta);
        }

        public int adjust_outer_gap (int delta) {
            return set_outer_gap (config.outer_gap + delta);
        }

        public int set_inner_gap (int value) {
            var new_gap = int.max (0, value);
            settings.set_int ("inner-gap", new_gap);
            return new_gap;
        }

        public int set_outer_gap (int value) {
            var new_gap = int.max (0, value);
            settings.set_int ("outer-gap", new_gap);
            return new_gap;
        }

        public bool set_master_enabled (bool enabled) {
            settings.set_boolean ("master-enabled", enabled);
            return enabled;
        }

        public string set_master_side (string side) {
            var normalized_side = normalize_master_side (side);
            settings.set_string ("master-side", normalized_side);
            return normalized_side;
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

        public bool focus_window_on_monitor (int monitor) {
            var workspace = display.get_workspace_manager ().get_active_workspace ();
            if (workspace == null || monitor < 0) {
                return false;
            }

            var group = groups[build_key (workspace.index (), monitor)];
            if (group == null || group.layout.is_empty) {
                return false;
            }

            Meta.Window? target = null;
            if (group.active_window != null && window_groups[group.active_window] == group) {
                target = group.active_window;
            } else {
                target = group.layout.get_any_tile () as Meta.Window;
            }

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

        public bool move_focused_window_to_monitor (int target_monitor) {
            var focus_window = display.focus_window;
            if (focus_window == null) {
                return false;
            }

            var source_group = window_groups[focus_window];
            if (source_group == null || target_monitor < 0 || source_group.monitor == target_monitor) {
                return false;
            }

            var workspace = focus_window.get_workspace ();
            if (workspace == null) {
                return false;
            }

            var target_key = build_key (workspace.index (), target_monitor);
            remove_window (focus_window);

            var target_group = get_or_create_group_for_location (workspace, target_monitor, target_key);
            Object? split_target = null;
            if (target_group.active_window != null
                && target_group.active_window != focus_window
                && target_group.layout.contains (target_group.active_window)) {
                split_target = target_group.active_window;
            }

            target_group.layout.insert (focus_window, split_target);
            target_group.active_window = focus_window;
            window_groups[focus_window] = target_group;
            window_monitor_hints[focus_window] = target_monitor;
            log_window_event (focus_window, "move-monitor", "%s -> %s".printf (source_group.key, target_group.key));

            focus_window.move_to_monitor (target_monitor);
            mark_group_dirty (target_group.key, true);
            schedule_flush ();
            focus_window.activate (display.get_current_time ());
            return true;
        }

        public bool promote_focused_window () {
            var focus_window = display.focus_window;
            if (focus_window == null) {
                return false;
            }

            var group = window_groups[focus_window];
            if (group == null || !group.layout.promote (focus_window)) {
                return false;
            }

            group.active_window = focus_window;
            mark_group_dirty (group.key, true);
            schedule_flush ();
            focus_window.activate (display.get_current_time ());
            return true;
        }

        public bool rotate_focused_group (bool forward = true) {
            var focus_window = display.focus_window;
            if (focus_window == null) {
                return false;
            }

            var group = window_groups[focus_window];
            if (group == null || !group.layout.rotate (forward)) {
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
            var reason = get_window_gate_rejection_reason (window, false);
            var should_manage = reason == "";
            log_window_gate ("should-manage-window", window, should_manage, false, reason);
            return should_manage;
        }

        private bool can_toggle_floating (Meta.Window window) {
            return window.window_type == Meta.WindowType.NORMAL
                && window.get_transient_for () == null
                && !NotificationStack.is_notification (window);
        }

        private void mark_window_first_frame_ready (Meta.Window window, string reason) {
            if (windows_with_first_frame.contains (window)) {
                return;
            }

            windows_waiting_for_first_frame.remove (window);
            windows_with_first_frame.add (window);
            log_window_event (window, "first-frame", reason);
            schedule_initial_sync_after_settle (window);
        }

        private bool can_assume_first_frame_ready (Meta.Window window) {
            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return false;
            }

            var frame_rect = window.get_frame_rect ();
            var buffer_rect = window.get_buffer_rect ();
            if (frame_rect.width <= 1 || frame_rect.height <= 1
                || buffer_rect.width <= 1 || buffer_rect.height <= 1) {
                return false;
            }

            float actor_width;
            float actor_height;
            actor.get_size (out actor_width, out actor_height);
            if (actor_width <= 1.0f || actor_height <= 1.0f) {
                return false;
            }

            if (window.get_client_type () == Meta.WindowClientType.X11) {
                return true;
            }

            return windows_waiting_for_map_reveal.contains (window)
                && is_potential_tile_candidate (window);
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

            if (can_assume_first_frame_ready (window)) {
                Idle.add (() => {
                    if (monitored_windows.contains (window)) {
                        mark_window_first_frame_ready (
                            window,
                            windows_waiting_for_map_reveal.contains (window)
                                ? "deferred-map-hook-fallback"
                                : "hook-fallback"
                        );
                    }

                    return Source.REMOVE;
                });
            }
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

            actor.remove_all_transitions ();
            actor.set_scale (1.0f, 1.0f);
            actor.rotation_angle_x = 0.0f;
            actor.rotation_angle_y = 0.0f;
            actor.rotation_angle_z = 0.0f;
            actor.set_pivot_point (0.0f, 0.0f);
            actor.set_translation (0.0f, 0.0f, 0.0f);
            actor.set_position (target_buffer_x, target_buffer_y);
            actor.set_size (target_buffer_width, target_buffer_height);
            log_window_event (
                window,
                "prepare-target-actor",
                "frame-target=(%d,%d %dx%d) buffer-target=(%d,%d %dx%d)".printf (
                    target_frame_rect.x,
                    target_frame_rect.y,
                    target_frame_rect.width,
                    target_frame_rect.height,
                    target_buffer_x,
                    target_buffer_y,
                    target_buffer_width,
                    target_buffer_height
                )
            );
        }

        private void restore_window_actor_visibility (Meta.Window window) {
            var actor = window.get_compositor_private () as Meta.WindowActor;
            if (actor == null || actor.is_destroyed ()) {
                return;
            }

            actor.opacity = 255U;
        }

        private string? get_group_key (Meta.Window window, bool allow_effective_workspace = false) {
            Meta.Workspace? workspace = allow_effective_workspace
                ? resolve_effective_workspace (window)
                : window.get_workspace ();
            if (workspace == null) {
                log_window_event (
                    window,
                    "group-key/no-workspace",
                    "allow-effective=%s".printf (allow_effective_workspace ? "true" : "false")
                );
                return null;
            }

            var monitor = resolve_window_monitor (window);
            if (monitor < 0) {
                log_window_event (
                    window,
                    "group-key/no-monitor",
                    "allow-effective=%s".printf (allow_effective_workspace ? "true" : "false")
                );
                return null;
            }

            return build_key (workspace.index (), monitor);
        }

        private string build_key (int workspace_index, int monitor) {
            return "%d:%d".printf (workspace_index, monitor);
        }

        private void mark_group_dirty (string key, bool settle = false) {
            dirty_groups.add (key);
        }

        private BspGroup get_or_create_group_for_location (Meta.Workspace workspace, int monitor, string key) {
            var group = groups[key];
            if (group != null) {
                configure_layout (group.layout);
                return group;
            }

            group = new BspGroup (workspace.index (), monitor, key);
            configure_layout (group.layout);
            groups[key] = group;
            return group;
        }

        private BspGroup get_or_create_group (Meta.Window window, string key) {
            return get_or_create_group_for_location (window.get_workspace (), resolve_window_monitor (window), key);
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
                if (rect_matches_target_without_expansion (frame_rect, rect)) {
                    clear_pending_frame_request (window);
                    if (windows_waiting_for_map_reveal.contains (window)) {
                        queue_window_target_ready (window, rect);
                    }

                    return;
                }

                var pending_request = pending_frame_requests[window];
                if (pending_request != null && rect_equals_with_tolerance (pending_request.rect, rect, 0)) {
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
                window_relayout_requested (window, frame_rect, rect);
                queue_pending_frame_request (window, frame_rect, rect);
                window.move_resize_frame (false, rect.x, rect.y, rect.width, rect.height);

                if (windows_waiting_for_map_reveal.contains (window)) {
                    queue_window_target_ready (window, rect);
                }
            }, get_tile_min_size);

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
            }, get_tile_min_size);

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

                    if (!windows_waiting_for_map_reveal.contains (placement.window)) {
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
            config.master_enabled = settings.get_boolean ("master-enabled");
            config.master_side = normalize_master_side (settings.get_string ("master-side"));
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
            var old_master_enabled = config.master_enabled;
            var old_master_side = config.master_side;
            var old_inner_gap = config.inner_gap;
            var old_outer_gap = config.outer_gap;
            var old_live_reorder = config.live_reorder_on_drag;

            load_settings ();

            switch (key) {
                case "enabled":
                case "scope":
                case "workspace-enabled":
                case "master-enabled":
                case "master-side":
                    if (old_enabled != config.enabled || old_scope != config.scope || key == "workspace-enabled") {
                        queue_full_rebuild ();
                    } else if (old_master_enabled != config.master_enabled || old_master_side != config.master_side) {
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

        private string normalize_master_side (string side) {
            return side == "right" ? "right" : "left";
        }

        private void configure_layout (BspLayout layout) {
            layout.set_master_options (config.master_enabled, config.master_side == "left");
        }

        private int resolve_window_monitor (Meta.Window window) {
            if (should_resolve_initial_monitor (window)) {
                var initial_monitor = resolve_initial_monitor (window);
                if (initial_monitor >= 0) {
                    log_monitor_resolution (window, "initial", initial_monitor);
                    return initial_monitor;
                }

                var current_group = window_groups[window];
                var group_monitor = current_group != null ? current_group.monitor : -1;
                log_monitor_resolution (window, "initial-group-fallback", group_monitor);
                return group_monitor;
            }

            var current_group = window_groups[window];
            if (current_group != null && should_hold_window_monitor_to_group (window)) {
                log_monitor_resolution (window, "group-hold", current_group.monitor);
                return current_group.monitor;
            }

            if (window_monitor_hints.has_key (window)) {
                var hinted_monitor = window_monitor_hints[window];
                if (hinted_monitor >= 0) {
                    log_monitor_resolution (window, "hint", hinted_monitor);
                    return hinted_monitor;
                }
            }

            var frame_rect = window.get_frame_rect ();
            if (frame_rect.width > 1 && frame_rect.height > 1) {
                var rect_monitor = display.get_monitor_index_for_rect (frame_rect);
                if (rect_monitor >= 0) {
                    log_monitor_resolution (window, "frame-rect", rect_monitor);
                    return rect_monitor;
                }
            }

            var buffer_rect = window.get_buffer_rect ();
            if (buffer_rect.width > 1 && buffer_rect.height > 1) {
                var rect_monitor = display.get_monitor_index_for_rect (buffer_rect);
                if (rect_monitor >= 0) {
                    log_monitor_resolution (window, "buffer-rect", rect_monitor);
                    return rect_monitor;
                }
            }

            var direct_monitor = window.get_monitor ();
            if (direct_monitor >= 0) {
                log_monitor_resolution (window, "raw-monitor", direct_monitor);
                return direct_monitor;
            }

            current_group = window_groups[window];
            var group_monitor = current_group != null ? current_group.monitor : -1;
            log_monitor_resolution (window, "group-fallback", group_monitor);
            return group_monitor;
        }

        private bool should_hold_window_monitor_to_group (Meta.Window window) {
            var current_group = window_groups[window];
            if (current_group == null || current_group.monitor < 0) {
                return false;
            }

            if (interactive_windows.contains (window)) {
                return false;
            }

            if (windows_waiting_for_map_reveal.contains (window)) {
                return true;
            }

            var pending_request = pending_frame_requests[window];
            if (pending_request == null) {
                return false;
            }

            var frame_rect = window.get_frame_rect ();
            if (rect_matches_target_without_expansion (frame_rect, pending_request.rect)) {
                return false;
            }

            var target_monitor = resolve_monitor_for_rect (pending_request.rect);
            return target_monitor >= 0 && target_monitor == current_group.monitor;
        }

        private bool should_resolve_initial_monitor (Meta.Window window) {
            return windows_waiting_for_map_reveal.contains (window)
                || (windows_waiting_for_first_frame.contains (window)
                    && !windows_with_first_frame.contains (window))
                || (window_initial_monitor_overrides.has_key (window)
                    && !window_groups.has_key (window))
                || should_preserve_initial_monitor_override (window);
        }

        private int resolve_initial_monitor (Meta.Window window) {
            var current_group = window_groups[window];
            if (current_group != null && current_group.monitor >= 0) {
                return current_group.monitor;
            }

            if (window_initial_monitor_overrides.has_key (window)) {
                var initial_monitor = window_initial_monitor_overrides[window];
                if (initial_monitor >= 0) {
                    return initial_monitor;
                }
            }

            if (window_monitor_hints.has_key (window)) {
                var hinted_monitor = window_monitor_hints[window];
                if (hinted_monitor >= 0) {
                    return hinted_monitor;
                }
            }

            var frame_monitor = resolve_monitor_for_rect (window.get_frame_rect ());
            if (frame_monitor >= 0) {
                return frame_monitor;
            }

            var buffer_monitor = resolve_monitor_for_rect (window.get_buffer_rect ());
            if (buffer_monitor >= 0) {
                return buffer_monitor;
            }

            return window.get_monitor ();
        }

        private bool should_preserve_initial_monitor_override (Meta.Window window) {
            if (!window_initial_monitor_overrides.has_key (window)) {
                return false;
            }

            var initial_monitor = window_initial_monitor_overrides[window];
            if (initial_monitor < 0) {
                return false;
            }

            var current_group = window_groups[window];
            if (current_group == null || current_group.monitor != initial_monitor) {
                return false;
            }

            if (window_monitor_hints.has_key (window) && window_monitor_hints[window] == initial_monitor) {
                return false;
            }

            var frame_monitor = resolve_monitor_for_rect (window.get_frame_rect ());
            if (frame_monitor == initial_monitor) {
                return true;
            }

            var buffer_monitor = resolve_monitor_for_rect (window.get_buffer_rect ());
            if (buffer_monitor == initial_monitor) {
                return true;
            }

            return window.get_monitor () == initial_monitor;
        }

        private Meta.Workspace? resolve_effective_workspace (Meta.Window window) {
            var workspace = window.get_workspace ();
            if (workspace != null) {
                return workspace;
            }

            return display.get_workspace_manager ().get_active_workspace ();
        }

        private string get_window_gate_rejection_reason (Meta.Window window, bool allow_effective_workspace) {
            if (NotificationStack.is_notification (window)) {
                return "notification";
            }

            if (window.window_type != Meta.WindowType.NORMAL) {
                return "window-type=%d".printf ((int) window.window_type);
            }

            if (window.get_transient_for () != null) {
                return "transient";
            }

            if (!window.allows_move ()) {
                return "disallow-move";
            }

            if (!window.allows_resize ()) {
                return "disallow-resize";
            }

            if (window.fullscreen) {
                return "fullscreen";
            }

            if (window.minimized) {
                return "minimized";
            }

            if (is_window_persistently_on_all_workspaces (window)) {
                return "all-workspaces";
            }

            if (window.is_above ()) {
                return "above";
            }

            if (window.maximized_horizontally || window.maximized_vertically) {
                return "maximized";
            }

            if (floating_windows.contains (window)) {
                return "floating";
            }

            var workspace = allow_effective_workspace
                ? resolve_effective_workspace (window)
                : window.get_workspace ();
            if (workspace == null) {
                return allow_effective_workspace ? "no-effective-workspace" : "no-workspace";
            }

            if (!is_workspace_enabled (workspace)) {
                return "workspace-disabled";
            }

            return "";
        }

        private bool is_window_persistently_on_all_workspaces (Meta.Window window) {
            return window.on_all_workspaces && meta_window_is_always_on_all_workspaces (window);
        }

        private int capture_preferred_initial_monitor (Meta.Window window) {
            var pointer_monitor = get_pointer_monitor ();
            if (pointer_monitor >= 0) {
                log_initial_monitor_capture (window, "pointer", pointer_monitor);
                return pointer_monitor;
            }

            var focus_window = display.focus_window;
            if (focus_window != null && focus_window != window) {
                var focus_group = window_groups[focus_window];
                if (focus_group != null) {
                    log_initial_monitor_capture (window, "focus-group", focus_group.monitor);
                    return focus_group.monitor;
                }

                var focus_frame_monitor = resolve_monitor_for_rect (focus_window.get_frame_rect ());
                if (focus_frame_monitor >= 0) {
                    log_initial_monitor_capture (window, "focus-frame", focus_frame_monitor);
                    return focus_frame_monitor;
                }

                var focus_buffer_monitor = resolve_monitor_for_rect (focus_window.get_buffer_rect ());
                if (focus_buffer_monitor >= 0) {
                    log_initial_monitor_capture (window, "focus-buffer", focus_buffer_monitor);
                    return focus_buffer_monitor;
                }

                var focus_monitor = focus_window.get_monitor ();
                if (focus_monitor >= 0) {
                    log_initial_monitor_capture (window, "focus-raw", focus_monitor);
                    return focus_monitor;
                }
            }

            var current_monitor = display.get_current_monitor ();
            if (current_monitor >= 0) {
                log_initial_monitor_capture (window, "current-monitor", current_monitor);
                return current_monitor;
            }

            log_initial_monitor_capture (window, "unresolved", -1);
            return -1;
        }

        private int resolve_monitor_for_rect (Mtk.Rectangle rect) {
            if (rect.width <= 1 || rect.height <= 1) {
                return -1;
            }

            return display.get_monitor_index_for_rect (rect);
        }

        private int get_pointer_monitor () {
            Graphene.Point coords = {};
#if HAS_MUTTER48
            unowned var cursor_tracker = display.get_compositor ().get_backend ().get_cursor_tracker ();
#else
            unowned var cursor_tracker = display.get_cursor_tracker ();
#endif
            cursor_tracker.get_pointer (out coords, null);

            Mtk.Rectangle rect = {
                (int) coords.x,
                (int) coords.y,
                1,
                1
            };
            return display.get_monitor_index_for_rect (rect);
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

        private void get_tile_min_size (Object tile, out int min_width, out int min_height) {
            min_width = 1;
            min_height = 1;

            var window = tile as Meta.Window;
            if (window == null) {
                return;
            }

            var minimum_size = observed_minimum_sizes[window];
            if (minimum_size == null) {
                return;
            }

            var gap_padding = int.max (0, config.inner_gap);
            min_width = int.max (1, minimum_size.width + gap_padding);
            min_height = int.max (1, minimum_size.height + gap_padding);
            log_observed_minimum_size (
                window,
                "use",
                minimum_size,
                null,
                null,
                null,
                "gap=%d result=(%dx%d)".printf (gap_padding, min_width, min_height)
            );
        }

        private void queue_pending_frame_request (Meta.Window window, Mtk.Rectangle old_rect, Mtk.Rectangle rect) {
            clear_pending_frame_request (window);

            var request = new BspPendingFrameRequest (old_rect, rect);
            pending_frame_requests[window] = request;
            request.timeout_id = Timeout.add (LAYOUT_REQUEST_TIMEOUT_MS, () => {
                if (pending_frame_requests[window] != request) {
                    return Source.REMOVE;
                }

                pending_frame_requests.unset (window);
                var frame_rect = window.get_frame_rect ();
                if (rect_matches_target_without_expansion (frame_rect, request.rect)) {
                    return Source.REMOVE;
                }

                var group = window_groups[window];
                if (group != null
                    && update_observed_minimum_size (window, frame_rect, request.old_rect, request.rect)) {
                    mark_group_dirty (group.key, true);
                    schedule_flush ();
                }

                return Source.REMOVE;
            });
        }

        private void clear_pending_frame_request (Meta.Window window) {
            var request = pending_frame_requests[window];
            if (request == null) {
                return;
            }

            if (request.timeout_id != 0) {
                Source.remove (request.timeout_id);
            }

            pending_frame_requests.unset (window);
        }

        private bool update_observed_minimum_size (
            Meta.Window window,
            Mtk.Rectangle actual_rect,
            Mtk.Rectangle old_rect,
            Mtk.Rectangle target_rect
        ) {
            var required_width = actual_rect.width > target_rect.width
                && abs_int (actual_rect.width - old_rect.width) > LAYOUT_SETTLE_TOLERANCE_PX
                ? actual_rect.width
                : 0;
            var required_height = actual_rect.height > target_rect.height
                && abs_int (actual_rect.height - old_rect.height) > LAYOUT_SETTLE_TOLERANCE_PX
                ? actual_rect.height
                : 0;

            if (required_width == 0 && required_height == 0) {
                return false;
            }

            var minimum_size = observed_minimum_sizes[window];
            if (minimum_size == null) {
                minimum_size = new BspWindowMinimumSize ();
                observed_minimum_sizes[window] = minimum_size;
            }

            var changed = false;
            if (required_width > 0 && required_width > minimum_size.width) {
                minimum_size.width = required_width;
                changed = true;
            }

            if (required_height > 0 && required_height > minimum_size.height) {
                minimum_size.height = required_height;
                changed = true;
            }

            if (changed) {
                log_observed_minimum_size (
                    window,
                    "update",
                    minimum_size,
                    actual_rect,
                    old_rect,
                    target_rect,
                    "required=(%d,%d)".printf (required_width, required_height)
                );
            }

            return changed;
        }

        private bool rect_equals_with_tolerance (Mtk.Rectangle first, Mtk.Rectangle second, int tolerance = 0) {
            return abs_int (first.x - second.x) <= tolerance
                && abs_int (first.y - second.y) <= tolerance
                && abs_int (first.width - second.width) <= tolerance
                && abs_int (first.height - second.height) <= tolerance;
        }

        private bool rect_matches_target_without_expansion (Mtk.Rectangle actual, Mtk.Rectangle target) {
            return abs_int (actual.x - target.x) <= LAYOUT_SETTLE_TOLERANCE_PX
                && abs_int (actual.y - target.y) <= LAYOUT_SETTLE_TOLERANCE_PX
                && actual.width <= target.width
                && actual.height <= target.height
                && abs_int (actual.width - target.width) <= LAYOUT_SETTLE_TOLERANCE_PX
                && abs_int (actual.height - target.height) <= LAYOUT_SETTLE_TOLERANCE_PX;
        }

        private int abs_int (int value) {
            return value < 0 ? -value : value;
        }

        private void log_window_event (Meta.Window window, string event, string extra = "") {
            if (!is_debug_enabled ()) {
                return;
            }

            var frame_rect = window.get_frame_rect ();
            var buffer_rect = window.get_buffer_rect ();
            var title = window.title ?? "(untitled)";
            var workspace = window.get_workspace ();
            var effective_workspace = resolve_effective_workspace (window);
            var group = window_groups[window];
            var group_key = group != null ? group.key : "-";
            var group_monitor = group != null ? group.monitor : -1;
            var raw_monitor = window.get_monitor ();
            var resolved_monitor = resolve_window_monitor (window);
            var initial_monitor = window_initial_monitor_overrides.has_key (window)
                ? window_initial_monitor_overrides[window]
                : -1;
            var hinted_monitor = window_monitor_hints.has_key (window)
                ? window_monitor_hints[window]
                : -1;
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
                "[BSP] %s title=\"%s\" group=%s workspace=%s effective-workspace=%s raw-monitor=%d resolved-monitor=%d group-monitor=%d hint=%d initial=%d frame=(%d,%d %dx%d)%s%s",
                event,
                title,
                group_key,
                workspace != null ? workspace.index ().to_string () : "null",
                effective_workspace != null ? effective_workspace.index ().to_string () : "null",
                raw_monitor,
                resolved_monitor,
                group_monitor,
                hinted_monitor,
                initial_monitor,
                frame_rect.x,
                frame_rect.y,
                frame_rect.width,
                frame_rect.height,
                suffix,
                actor_state
            );
        }

        private void log_window_gate (
            string gate,
            Meta.Window window,
            bool result,
            bool allow_effective_workspace,
            string reason = ""
        ) {
            if (!is_debug_enabled ()) {
                return;
            }

            var workspace = window.get_workspace ();
            var effective_workspace = resolve_effective_workspace (window);
            var resolved_monitor = resolve_window_monitor (window);

            message (
                "[BSP] %s title=\"%s\" result=%s reason=%s workspace=%s effective-workspace=%s raw-monitor=%d resolved-monitor=%d type=%d allows-move=%s allows-resize=%s transient=%s floating=%s all-workspaces=%s always-all-workspaces=%s",
                gate,
                window.title ?? "(untitled)",
                result ? "true" : "false",
                reason != "" ? reason : "ok",
                workspace != null ? workspace.index ().to_string () : "null",
                allow_effective_workspace && effective_workspace != null ? effective_workspace.index ().to_string () : "null",
                window.get_monitor (),
                resolved_monitor,
                (int) window.window_type,
                window.allows_move () ? "true" : "false",
                window.allows_resize () ? "true" : "false",
                window.get_transient_for () != null ? "true" : "false",
                floating_windows.contains (window) ? "true" : "false",
                window.on_all_workspaces ? "true" : "false",
                is_window_persistently_on_all_workspaces (window) ? "true" : "false"
            );
        }

        private void log_monitor_resolution (Meta.Window window, string source, int resolved_monitor) {
            if (!is_debug_enabled ()) {
                return;
            }

            var workspace = window.get_workspace ();
            var effective_workspace = resolve_effective_workspace (window);
            var group = window_groups[window];
            var group_monitor = group != null ? group.monitor : -1;
            var initial_monitor = window_initial_monitor_overrides.has_key (window)
                ? window_initial_monitor_overrides[window]
                : -1;
            var hinted_monitor = window_monitor_hints.has_key (window)
                ? window_monitor_hints[window]
                : -1;

            message (
                "[BSP] resolve-monitor title=\"%s\" source=%s resolved=%d raw=%d group-monitor=%d hint=%d initial=%d workspace=%s effective-workspace=%s waiting-map=%s waiting-frame=%s",
                window.title ?? "(untitled)",
                source,
                resolved_monitor,
                window.get_monitor (),
                group_monitor,
                hinted_monitor,
                initial_monitor,
                workspace != null ? workspace.index ().to_string () : "null",
                effective_workspace != null ? effective_workspace.index ().to_string () : "null",
                windows_waiting_for_map_reveal.contains (window) ? "true" : "false",
                windows_waiting_for_first_frame.contains (window) && !windows_with_first_frame.contains (window) ? "true" : "false"
            );
        }

        private void log_initial_monitor_capture (Meta.Window window, string source, int monitor) {
            if (!is_debug_enabled ()) {
                return;
            }

            var workspace = window.get_workspace ();
            var effective_workspace = resolve_effective_workspace (window);

            message (
                "[BSP] capture-initial-monitor title=\"%s\" source=%s monitor=%d workspace=%s effective-workspace=%s raw-monitor=%d",
                window.title ?? "(untitled)",
                source,
                monitor,
                workspace != null ? workspace.index ().to_string () : "null",
                effective_workspace != null ? effective_workspace.index ().to_string () : "null",
                window.get_monitor ()
            );
        }

        private void log_observed_minimum_size (
            Meta.Window window,
            string event,
            BspWindowMinimumSize minimum_size,
            Mtk.Rectangle? actual_rect = null,
            Mtk.Rectangle? old_rect = null,
            Mtk.Rectangle? target_rect = null,
            string extra = ""
        ) {
            if (!is_debug_enabled ()) {
                return;
            }

            var workspace = window.get_workspace ();
            var effective_workspace = resolve_effective_workspace (window);
            var actual = actual_rect ?? window.get_frame_rect ();
            Mtk.Rectangle old_state = { 0, 0, 0, 0 };
            Mtk.Rectangle target_state = { 0, 0, 0, 0 };
            var has_old_rect = old_rect != null;
            var has_target_rect = target_rect != null;

            if (old_rect != null) {
                old_state = (!) old_rect;
            }

            if (target_rect != null) {
                target_state = (!) target_rect;
            }

            message (
                "[BSP] min-size-%s title=\"%s\" min=(%d,%d) workspace=%s effective-workspace=%s raw-monitor=%d resolved-monitor=%d actual=(%d,%d %dx%d) old=(%d,%d %dx%d)%s target=(%d,%d %dx%d)%s%s",
                event,
                window.title ?? "(untitled)",
                minimum_size.width,
                minimum_size.height,
                workspace != null ? workspace.index ().to_string () : "null",
                effective_workspace != null ? effective_workspace.index ().to_string () : "null",
                window.get_monitor (),
                resolve_window_monitor (window),
                actual.x,
                actual.y,
                actual.width,
                actual.height,
                old_state.x,
                old_state.y,
                old_state.width,
                old_state.height,
                has_old_rect ? "" : " (unset)",
                target_state.x,
                target_state.y,
                target_state.width,
                target_state.height,
                has_target_rect ? "" : " (unset)",
                extra != "" ? " %s".printf (extra) : ""
            );
        }
    }
}
