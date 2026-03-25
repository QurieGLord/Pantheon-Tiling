namespace PanelBsp {
    [DBus (name = "org.pantheon.gala")]
    private interface GalaBspControl : Object {
        public abstract bool get_bsp_enabled () throws DBusError, IOError;
        public abstract string get_bsp_scope () throws DBusError, IOError;
        public abstract bool get_bsp_enabled_for_active_workspace () throws DBusError, IOError;
        public abstract int get_bsp_inner_gap () throws DBusError, IOError;
        public abstract int get_bsp_outer_gap () throws DBusError, IOError;
        public abstract bool toggle_bsp_enabled () throws DBusError, IOError;
        public abstract bool toggle_bsp_active_workspace_enabled () throws DBusError, IOError;
        public abstract bool toggle_bsp_focused_window_floating () throws DBusError, IOError;
        public abstract bool promote_bsp_focused_window () throws DBusError, IOError;
        public abstract bool rotate_bsp_group_forward () throws DBusError, IOError;
        public abstract bool rotate_bsp_group_backward () throws DBusError, IOError;
    }

    public class BspState : Object {
        public bool enabled { get; set; default = false; }
        public string scope { get; set; default = "global"; }
        public bool active_workspace_enabled { get; set; default = false; }
        public int inner_gap { get; set; default = 0; }
        public int outer_gap { get; set; default = 0; }
    }

    public class GalaClient : Object {
        private GalaBspControl? proxy = null;

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
                return true;
            } catch (Error e) {
                warning ("Failed to connect to Gala BSP D-Bus API: %s", e.message);
                proxy = null;
                return false;
            }
        }

        private void invalidate_proxy () {
            proxy = null;
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
    }
}
