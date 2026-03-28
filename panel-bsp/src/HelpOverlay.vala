namespace PanelBsp {
    private class ShortcutItem : Object {
        public string id { get; construct; }
        public string title { get; construct; }

        public ShortcutItem (string id, string title) {
            Object (id: id, title: title);
        }
    }

    public class HelpOverlay : Object {
        private GLib.Settings keybinding_settings;
        private Gtk.Application? application;
        private Gtk.Window window;
        private Gee.HashMap<string, Gtk.Label> shortcut_labels = new Gee.HashMap<string, Gtk.Label> ();

        public HelpOverlay (GLib.Settings keybinding_settings, Gtk.Application? application = null) {
            this.keybinding_settings = keybinding_settings;
            this.application = application;
            window = build_window ();

            this.keybinding_settings.changed.connect (() => {
                refresh_shortcuts ();
            });

            refresh_shortcuts ();
        }

        public void present () {
            refresh_shortcuts ();
            window.show_all ();
            window.present ();
        }

        private Gtk.Window build_window () {
            var help_window = new Gtk.Window (Gtk.WindowType.TOPLEVEL) {
                title = "BSP Tiling Help",
                default_width = 720,
                default_height = 560,
                resizable = true,
                modal = false,
                window_position = Gtk.WindowPosition.CENTER
            };
            if (application != null) {
                help_window.application = application;
            }

            help_window.set_type_hint (Gdk.WindowTypeHint.DIALOG);
            help_window.delete_event.connect (() => {
                help_window.hide ();
                return true;
            });

            var outer_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
                margin_top = 18,
                margin_bottom = 18,
                margin_start = 18,
                margin_end = 18
            };

            var title = new Gtk.Label ("") {
                halign = Gtk.Align.START,
                xalign = 0.0f,
                use_markup = true,
                wrap = true,
                label = "<span size='x-large' weight='bold'>BSP Tiling Help</span>"
            };
            outer_box.pack_start (title, false, false, 0);

            var subtitle = new Gtk.Label (
                "These shortcuts reflect the current Gala keybindings. Changes in System Settings or dconf are shown here automatically."
            ) {
                halign = Gtk.Align.START,
                xalign = 0.0f,
                wrap = true
            };
            subtitle.get_style_context ().add_class ("dim-label");
            outer_box.pack_start (subtitle, false, false, 0);

            var scrolled = new Gtk.ScrolledWindow (null, null) {
                hscrollbar_policy = Gtk.PolicyType.NEVER,
                vscrollbar_policy = Gtk.PolicyType.AUTOMATIC,
                expand = true
            };

            var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 18);
            append_section (content, "Focus", {
                new ShortcutItem ("switch-to-workspace-left", "Focus tile to the left"),
                new ShortcutItem ("switch-to-workspace-right", "Focus tile to the right"),
                new ShortcutItem ("bsp-focus-up", "Focus tile above"),
                new ShortcutItem ("bsp-focus-down", "Focus tile below")
            });
            append_section (content, "Swap and Rearrange", {
                new ShortcutItem ("move-to-monitor-left", "Swap with the tile to the left"),
                new ShortcutItem ("move-to-monitor-right", "Swap with the tile to the right"),
                new ShortcutItem ("bsp-move-up", "Swap with the tile above"),
                new ShortcutItem ("bsp-move-down", "Swap with the tile below"),
                new ShortcutItem ("bsp-promote", "Promote focused window to the master slot"),
                new ShortcutItem ("bsp-rotate-forward", "Rotate the BSP tree forward"),
                new ShortcutItem ("bsp-rotate-backward", "Rotate the BSP tree backward")
            });
            append_section (content, "Modes", {
                new ShortcutItem ("bsp-toggle-tiling", "Toggle BSP globally"),
                new ShortcutItem ("bsp-toggle-workspace-tiling", "Toggle BSP for the current workspace"),
                new ShortcutItem ("bsp-toggle-floating", "Toggle the focused window between tiled and floating")
            });
            append_section (content, "Spacing", {
                new ShortcutItem ("bsp-increase-inner-gap", "Increase the inner gap"),
                new ShortcutItem ("bsp-decrease-inner-gap", "Decrease the inner gap"),
                new ShortcutItem ("bsp-increase-outer-gap", "Increase the outer gap"),
                new ShortcutItem ("bsp-decrease-outer-gap", "Decrease the outer gap")
            });

            scrolled.add (content);
            outer_box.pack_start (scrolled, true, true, 0);

            var close_button = new Gtk.Button.with_label ("Close");
            close_button.halign = Gtk.Align.END;
            close_button.clicked.connect (() => {
                help_window.hide ();
            });
            outer_box.pack_start (close_button, false, false, 0);

            help_window.add (outer_box);
            return help_window;
        }

        private void append_section (Gtk.Box parent, string title, ShortcutItem[] items) {
            var section_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 8);

            var title_label = new Gtk.Label ("") {
                halign = Gtk.Align.START,
                xalign = 0.0f,
                use_markup = true,
                label = "<b>%s</b>".printf (GLib.Markup.escape_text (title))
            };
            section_box.pack_start (title_label, false, false, 0);

            var grid = new Gtk.Grid () {
                row_spacing = 8,
                column_spacing = 16,
                hexpand = true
            };

            var row = 0;
            foreach (var item in items) {
                var description = new Gtk.Label (item.title) {
                    halign = Gtk.Align.START,
                    xalign = 0.0f,
                    wrap = true,
                    hexpand = true
                };
                grid.attach (description, 0, row, 1, 1);

                var shortcut = new Gtk.Label ("") {
                    halign = Gtk.Align.END,
                    xalign = 1.0f,
                    selectable = true
                };
                shortcut.get_style_context ().add_class ("dim-label");
                grid.attach (shortcut, 1, row, 1, 1);
                shortcut_labels[item.id] = shortcut;
                row++;
            }

            section_box.pack_start (grid, false, false, 0);
            parent.pack_start (section_box, false, false, 0);
        }

        private void refresh_shortcuts () {
            foreach (var entry in shortcut_labels.entries) {
                entry.value.label = lookup_shortcut_label (entry.key);
            }
        }

        private string lookup_shortcut_label (string key) {
            var bindings = keybinding_settings.get_strv (key);
            if (bindings.length == 0) {
                return "Unassigned";
            }

            return format_binding (bindings[0]);
        }

        private string format_binding (string binding) {
            if (binding == null || binding == "") {
                return "Unassigned";
            }

            uint accel_key = 0;
            Gdk.ModifierType accel_mods = 0;
            Gtk.accelerator_parse (binding, out accel_key, out accel_mods);
            if (accel_key != 0) {
                return Gtk.accelerator_get_label (accel_key, accel_mods);
            }

            return binding;
        }
    }
}
