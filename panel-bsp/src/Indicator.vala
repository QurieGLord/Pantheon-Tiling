public class PanelBsp.Indicator : Wingpanel.Indicator {
    private const string BSP_SCHEMA = "io.elementary.desktop.wm.bsp";
    private const string BEHAVIOR_SCHEMA = "io.elementary.desktop.wm.behavior";

    private GalaClient gala_client;
    private GLib.Settings bsp_settings;
    private GLib.Settings behavior_settings;

    private Gtk.Image display_icon;
    private Gtk.Box? popover_widget = null;
    private Gtk.Label? status_label = null;
    private Gtk.Switch? bsp_enabled_switch = null;
    private Gtk.Switch? workspace_switch = null;
    private Gtk.Switch? focus_follows_mouse_switch = null;
    private Gtk.Switch? mouse_follows_focus_switch = null;
    private Gtk.Switch? live_reorder_switch = null;
    private Gtk.SpinButton? inner_gap_spin = null;
    private Gtk.SpinButton? outer_gap_spin = null;
    private Gtk.Button? float_button = null;
    private Gtk.Button? promote_button = null;
    private Gtk.Button? rotate_button = null;
    private Gtk.Button? rotate_back_button = null;

    private bool syncing_controls = false;

    public Indicator () {
        Object (
            code_name: "bsp"
        );
    }

    construct {
        gala_client = new GalaClient ();
        bsp_settings = new GLib.Settings (BSP_SCHEMA);
        behavior_settings = new GLib.Settings (BEHAVIOR_SCHEMA);

        display_icon = new Gtk.Image.from_icon_name ("view-grid-symbolic") {
            pixel_size = 16
        };

        visible = true;

        bsp_settings.changed.connect (refresh_ui);
        behavior_settings.changed.connect (refresh_ui);
        refresh_ui ();
    }

    public override Gtk.Widget get_display_widget () {
        return display_icon;
    }

    public override Gtk.Widget? get_widget () {
        if (popover_widget == null) {
            build_popover ();
        }

        refresh_ui ();
        return popover_widget;
    }

    public override void opened () {
        refresh_ui ();
    }

    public override void closed () {
    }

    private void build_popover () {
        popover_widget = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12,
            width_request = 340
        };

        var title_label = new Gtk.Label ("BSP Tiling") {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.add_css_class ("title-4");
        popover_widget.append (title_label);

        status_label = new Gtk.Label ("") {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        status_label.add_css_class ("dim-label");
        popover_widget.append (status_label);

        popover_widget.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

        popover_widget.append (create_switch_row (
            "Enable BSP",
            "Turn tiling on or off globally",
            out bsp_enabled_switch
        ));
        bsp_enabled_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bool current_state;
            gala_client.ensure_bsp_enabled (bsp_enabled_switch.active, out current_state);
            refresh_ui ();
        });

        popover_widget.append (create_switch_row (
            "This Workspace",
            "Enable BSP for the current workspace",
            out workspace_switch
        ));
        workspace_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bool current_state;
            gala_client.ensure_active_workspace_enabled (workspace_switch.active, out current_state);
            refresh_ui ();
        });

        popover_widget.append (create_spin_row (
            "Inner Gap",
            "Gap between tiled windows",
            out inner_gap_spin
        ));
        inner_gap_spin.value_changed.connect (() => {
            if (syncing_controls) {
                return;
            }

            bsp_settings.set_int ("inner-gap", (int) inner_gap_spin.get_value ());
        });

        popover_widget.append (create_spin_row (
            "Outer Gap",
            "Gap between the layout and the screen edge",
            out outer_gap_spin
        ));
        outer_gap_spin.value_changed.connect (() => {
            if (syncing_controls) {
                return;
            }

            bsp_settings.set_int ("outer-gap", (int) outer_gap_spin.get_value ());
        });

        popover_widget.append (create_switch_row (
            "Live Reorder",
            "Rebuild the BSP tree while dragging tiled windows",
            out live_reorder_switch
        ));
        live_reorder_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bsp_settings.set_boolean ("live-reorder-on-drag", live_reorder_switch.active);
        });

        popover_widget.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

        popover_widget.append (create_switch_row (
            "Focus Follows Mouse",
            "Focus windows when the pointer enters them",
            out focus_follows_mouse_switch
        ));
        focus_follows_mouse_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            behavior_settings.set_boolean ("focus-follows-mouse", focus_follows_mouse_switch.active);
        });

        popover_widget.append (create_switch_row (
            "Mouse Follows Focus",
            "Warp the pointer to the newly focused window",
            out mouse_follows_focus_switch
        ));
        mouse_follows_focus_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            behavior_settings.set_boolean ("mouse-follows-focus", mouse_follows_focus_switch.active);
        });

        popover_widget.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

        var actions_label = new Gtk.Label ("Window Actions") {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        actions_label.add_css_class ("heading");
        popover_widget.append (actions_label);

        var actions_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            homogeneous = true
        };
        float_button = create_action_button ("Float", () => {
            gala_client.toggle_focused_window_floating ();
            refresh_ui ();
        });
        actions_box.append (float_button);

        promote_button = create_action_button ("Promote", () => {
            gala_client.promote_focused_window ();
            refresh_ui ();
        });
        actions_box.append (promote_button);

        rotate_button = create_action_button ("Rotate", () => {
            gala_client.rotate_group_forward ();
            refresh_ui ();
        });
        actions_box.append (rotate_button);

        rotate_back_button = create_action_button ("Rotate Back", () => {
            gala_client.rotate_group_backward ();
            refresh_ui ();
        });
        actions_box.append (rotate_back_button);
        popover_widget.append (actions_box);
    }

    private Gtk.Widget create_switch_row (string title, string subtitle, out Gtk.Switch switch_widget) {
        var title_label = new Gtk.Label (title) {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.add_css_class ("heading");

        var subtitle_label = new Gtk.Label (subtitle) {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        subtitle_label.add_css_class ("dim-label");

        var labels_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true
        };
        labels_box.append (title_label);
        labels_box.append (subtitle_label);

        switch_widget = new Gtk.Switch () {
            halign = Gtk.Align.END,
            valign = Gtk.Align.CENTER
        };

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.append (labels_box);
        row.append (switch_widget);
        return row;
    }

    private Gtk.Widget create_spin_row (string title, string subtitle, out Gtk.SpinButton spin_button) {
        var title_label = new Gtk.Label (title) {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.add_css_class ("heading");

        var subtitle_label = new Gtk.Label (subtitle) {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        subtitle_label.add_css_class ("dim-label");

        var labels_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true
        };
        labels_box.append (title_label);
        labels_box.append (subtitle_label);

        spin_button = new Gtk.SpinButton.with_range (0, 96, 1) {
            halign = Gtk.Align.END,
            valign = Gtk.Align.CENTER,
            width_chars = 4,
            numeric = true
        };

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.append (labels_box);
        row.append (spin_button);
        return row;
    }

    private Gtk.Button create_action_button (string title, owned ActionCallback callback) {
        var button = new Gtk.Button.with_label (title);
        button.add_css_class (Granite.STYLE_CLASS_FLAT);
        button.clicked.connect (() => {
            callback ();
        });

        return button;
    }

    private void refresh_ui () {
        var active_scope = "global";
        var global_enabled = bsp_settings.get_boolean ("enabled");
        var active_workspace_enabled = global_enabled;
        var inner_gap = bsp_settings.get_int ("inner-gap");
        var outer_gap = bsp_settings.get_int ("outer-gap");
        var has_gala_state = false;

        BspState gala_state;
        if (gala_client.try_get_state (out gala_state)) {
            active_scope = gala_state.scope;
            global_enabled = gala_state.enabled;
            active_workspace_enabled = gala_state.active_workspace_enabled;
            inner_gap = gala_state.inner_gap;
            outer_gap = gala_state.outer_gap;
            has_gala_state = true;
        } else {
            active_scope = bsp_settings.get_string ("scope");
            if (active_scope == "workspace") {
                active_workspace_enabled = false;
            }
        }

        var behavior_focus_follows_mouse = behavior_settings.get_boolean ("focus-follows-mouse");
        var behavior_mouse_follows_focus = behavior_settings.get_boolean ("mouse-follows-focus");
        var live_reorder = bsp_settings.get_boolean ("live-reorder-on-drag");

        syncing_controls = true;

        if (status_label != null) {
            var mode_text = active_scope == "workspace" ? "Per-workspace" : "Global";
            status_label.label = has_gala_state
                ? "Mode: %s\nCurrent workspace: %s\nInner gap: %d px\nOuter gap: %d px".printf (
                    mode_text,
                    active_workspace_enabled ? "enabled" : "disabled",
                    inner_gap,
                    outer_gap
                )
                : "Gala BSP service is not reachable right now. The panel can still edit direct GSettings values.";
        }

        if (bsp_enabled_switch != null) {
            bsp_enabled_switch.active = global_enabled;
            bsp_enabled_switch.sensitive = has_gala_state;
        }

        if (workspace_switch != null) {
            workspace_switch.active = active_workspace_enabled;
            workspace_switch.sensitive = has_gala_state;
        }

        if (inner_gap_spin != null) {
            inner_gap_spin.set_value ((double) inner_gap);
        }

        if (outer_gap_spin != null) {
            outer_gap_spin.set_value ((double) outer_gap);
        }

        if (live_reorder_switch != null) {
            live_reorder_switch.active = live_reorder;
        }

        if (focus_follows_mouse_switch != null) {
            focus_follows_mouse_switch.active = behavior_focus_follows_mouse;
        }

        if (mouse_follows_focus_switch != null) {
            mouse_follows_focus_switch.active = behavior_mouse_follows_focus;
        }

        if (float_button != null) {
            float_button.sensitive = has_gala_state;
        }

        if (promote_button != null) {
            promote_button.sensitive = has_gala_state;
        }

        if (rotate_button != null) {
            rotate_button.sensitive = has_gala_state;
        }

        if (rotate_back_button != null) {
            rotate_back_button.sensitive = has_gala_state;
        }

        display_icon.opacity = active_workspace_enabled ? 1.0 : 0.55;
        display_icon.tooltip_text = "BSP: %s, inner gap %d px, outer gap %d px".printf (
            active_workspace_enabled ? "enabled" : "disabled",
            inner_gap,
            outer_gap
        );

        syncing_controls = false;
    }

    private delegate void ActionCallback ();
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    debug ("Activating BSP Indicator");

    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    return new PanelBsp.Indicator ();
}
