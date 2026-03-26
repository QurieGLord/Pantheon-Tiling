namespace PanelBsp {
    [DBus (name = "org.pantheon.gala")]
    private interface GalaBspControl : Object {
        public abstract bool get_bsp_enabled () throws DBusError, IOError;
        public abstract string get_bsp_scope () throws DBusError, IOError;
        public abstract bool get_bsp_enabled_for_active_workspace () throws DBusError, IOError;
        public abstract bool get_bsp_master_enabled () throws DBusError, IOError;
        public abstract string get_bsp_master_side () throws DBusError, IOError;
        public abstract int get_bsp_inner_gap () throws DBusError, IOError;
        public abstract int get_bsp_outer_gap () throws DBusError, IOError;
        public abstract bool toggle_bsp_enabled () throws DBusError, IOError;
        public abstract bool toggle_bsp_active_workspace_enabled () throws DBusError, IOError;
        public abstract bool toggle_bsp_focused_window_floating () throws DBusError, IOError;
        public abstract bool set_bsp_master_enabled (bool enabled) throws DBusError, IOError;
        public abstract string set_bsp_master_side (string side) throws DBusError, IOError;
        public abstract int set_bsp_inner_gap (int value) throws DBusError, IOError;
        public abstract int set_bsp_outer_gap (int value) throws DBusError, IOError;
        public abstract bool promote_bsp_focused_window () throws DBusError, IOError;
        public abstract bool rotate_bsp_group_forward () throws DBusError, IOError;
        public abstract bool rotate_bsp_group_backward () throws DBusError, IOError;
    }

    public class BspState : Object {
        public bool enabled { get; set; default = false; }
        public string scope { get; set; default = "global"; }
        public bool active_workspace_enabled { get; set; default = false; }
        public bool master_enabled { get; set; default = true; }
        public string master_side { get; set; default = "left"; }
        public int inner_gap { get; set; default = 0; }
        public int outer_gap { get; set; default = 0; }
    }

    public class GalaClient : Object {
        private GalaBspControl? proxy = null;
        private uint watch_id = 0;
        private bool name_available = false;
        private bool availability_known = false;

        public signal void availability_changed (bool available);

        construct {
            watch_id = Bus.watch_name (
                BusType.SESSION,
                "org.pantheon.gala",
                BusNameWatcherFlags.NONE,
                (connection, name, owner) => {
                    proxy = null;
                    update_availability (true);
                },
                (connection, name) => {
                    proxy = null;
                    update_availability (false);
                }
            );
        }

        ~GalaClient () {
            if (watch_id != 0) {
                Bus.unwatch_name (watch_id);
                watch_id = 0;
            }
        }

        private void update_availability (bool available) {
            if (availability_known && name_available == available) {
                return;
            }

            availability_known = true;
            name_available = available;
            availability_changed (available);
        }

        private bool ensure_proxy () {
            if (proxy != null) {
                return true;
            }

            try {
                proxy = Bus.get_proxy_sync<GalaBspControl> (
                    BusType.SESSION,
                    "org.pantheon.gala",
                    "/org/pantheon/gala"
                );
                update_availability (true);
                return true;
            } catch (Error e) {
                if (name_available) {
                    warning ("Failed to connect to Gala BSP D-Bus API: %s", e.message);
                }

                proxy = null;
                update_availability (false);
                return false;
            }
        }

        private void invalidate_proxy () {
            proxy = null;
        }

        public bool is_available () {
            return proxy != null || name_available;
        }

        public bool try_get_state (out BspState state) {
            state = new BspState ();
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                state.enabled = proxy.get_bsp_enabled ();
                state.scope = proxy.get_bsp_scope ();
                state.active_workspace_enabled = proxy.get_bsp_enabled_for_active_workspace ();
                state.master_enabled = proxy.get_bsp_master_enabled ();
                state.master_side = proxy.get_bsp_master_side ();
                state.inner_gap = proxy.get_bsp_inner_gap ();
                state.outer_gap = proxy.get_bsp_outer_gap ();
                return true;
            } catch (Error e) {
                warning ("Failed to fetch BSP state from Gala: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool ensure_bsp_enabled (bool desired, out bool current_state) {
            current_state = false;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                current_state = proxy.get_bsp_enabled ();
                if (current_state != desired) {
                    current_state = proxy.toggle_bsp_enabled ();
                }

                return true;
            } catch (Error e) {
                warning ("Failed to toggle BSP enabled state: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool ensure_active_workspace_enabled (bool desired, out bool current_state) {
            current_state = false;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                current_state = proxy.get_bsp_enabled_for_active_workspace ();
                if (current_state != desired) {
                    current_state = proxy.toggle_bsp_active_workspace_enabled ();
                }

                return true;
            } catch (Error e) {
                warning ("Failed to toggle BSP state for the active workspace: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool toggle_focused_window_floating () {
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                return proxy.toggle_bsp_focused_window_floating ();
            } catch (Error e) {
                warning ("Failed to toggle focused window floating mode: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool promote_focused_window () {
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                return proxy.promote_bsp_focused_window ();
            } catch (Error e) {
                warning ("Failed to promote focused BSP window: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool rotate_group_forward () {
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                return proxy.rotate_bsp_group_forward ();
            } catch (Error e) {
                warning ("Failed to rotate BSP group forward: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool rotate_group_backward () {
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                return proxy.rotate_bsp_group_backward ();
            } catch (Error e) {
                warning ("Failed to rotate BSP group backward: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool set_master_enabled (bool enabled, out bool current_state) {
            current_state = enabled;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                current_state = proxy.set_bsp_master_enabled (enabled);
                return true;
            } catch (Error e) {
                warning ("Failed to update BSP master mode: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool set_master_side (string side, out string applied_side) {
            applied_side = side;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                applied_side = proxy.set_bsp_master_side (side);
                return true;
            } catch (Error e) {
                warning ("Failed to update BSP master side: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool set_inner_gap (int value, out int current_value) {
            current_value = value;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                current_value = proxy.set_bsp_inner_gap (value);
                return true;
            } catch (Error e) {
                warning ("Failed to update BSP inner gap: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }

        public bool set_outer_gap (int value, out int current_value) {
            current_value = value;
            if (!ensure_proxy ()) {
                return false;
            }

            try {
                current_value = proxy.set_bsp_outer_gap (value);
                return true;
            } catch (Error e) {
                warning ("Failed to update BSP outer gap: %s", e.message);
                invalidate_proxy ();
                return false;
            }
        }
    }
}
