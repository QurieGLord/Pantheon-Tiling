namespace PanelBsp {
    public class HelpOverlay : Object {
        private const string RESOURCE_PATH = "/io/elementary/panel/bsp/help-overlay.ui";

        private GLib.Settings keybinding_settings;
        private Gtk.Builder builder;
        private Gtk.ShortcutsWindow window;

        public HelpOverlay (GLib.Settings keybinding_settings) {
            this.keybinding_settings = keybinding_settings;

            builder = new Gtk.Builder.from_resource (RESOURCE_PATH);
            window = builder.get_object ("bsp_help_window") as Gtk.ShortcutsWindow;
            assert (window != null);

            window.close_request.connect (() => {
                window.hide ();
                return true;
            });

            this.keybinding_settings.changed.connect (() => {
                refresh_shortcuts ();
            });

            refresh_shortcuts ();
        }

        public void present () {
            refresh_shortcuts ();
            window.present ();
        }

        private void refresh_shortcuts () {
            update_shortcut ("focus_left", "switch-to-workspace-left");
            update_shortcut ("focus_right", "switch-to-workspace-right");
            update_shortcut ("focus_up", "bsp-focus-up");
            update_shortcut ("focus_down", "bsp-focus-down");

            update_shortcut ("swap_left", "move-to-monitor-left");
            update_shortcut ("swap_right", "move-to-monitor-right");
            update_shortcut ("swap_up", "move-to-monitor-up");
            update_shortcut ("swap_down", "move-to-monitor-down");

            update_shortcut ("toggle_global", "bsp-toggle-tiling");
            update_shortcut ("toggle_workspace", "bsp-toggle-workspace-tiling");
            update_shortcut ("toggle_floating", "bsp-toggle-floating");
            update_shortcut ("promote", "bsp-promote");
            update_shortcut ("rotate_forward", "bsp-rotate-forward");
            update_shortcut ("rotate_backward", "bsp-rotate-backward");

            update_shortcut ("increase_inner", "bsp-increase-inner-gap");
            update_shortcut ("decrease_inner", "bsp-decrease-inner-gap");
            update_shortcut ("increase_outer", "bsp-increase-outer-gap");
            update_shortcut ("decrease_outer", "bsp-decrease-outer-gap");
        }

        private void update_shortcut (string object_id, string key) {
            var shortcut = builder.get_object (object_id) as Gtk.ShortcutsShortcut;
            if (shortcut == null) {
                return;
            }

            var bindings = keybinding_settings.get_strv (key);
            if (bindings.length == 0) {
                shortcut.visible = false;
                return;
            }

            shortcut.visible = true;
            shortcut.accelerator = bindings[0];
        }
    }
}
