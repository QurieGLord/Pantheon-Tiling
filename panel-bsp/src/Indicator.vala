public class PanelBsp.Indicator : Wingpanel.Indicator {
    private const string BSP_SCHEMA = "io.elementary.desktop.wm.bsp";
    private const string BEHAVIOR_SCHEMA = "io.elementary.desktop.wm.behavior";
    private const string KEYBINDINGS_SCHEMA = "io.elementary.desktop.wm.keybindings";

    private GalaClient gala_client;
    private GLib.Settings bsp_settings;
    private GLib.Settings behavior_settings;
    private GLib.Settings keybinding_settings;
    private HelpOverlay? help_overlay = null;

    private Gtk.Image display_icon;
    private Gtk.Box? popover_widget = null;
    private Gtk.Label? status_label = null;
    private Gtk.Switch? bsp_enabled_switch = null;
    private Gtk.Switch? workspace_switch = null;
    private Gtk.Switch? master_enabled_switch = null;
    private Gtk.Switch? focus_follows_mouse_switch = null;
    private Gtk.Switch? mouse_follows_focus_switch = null;
    private Gtk.Switch? live_reorder_switch = null;
    private Gtk.ComboBoxText? master_side_combo = null;
    private Gtk.SpinButton? inner_gap_spin = null;
    private Gtk.SpinButton? outer_gap_spin = null;
    private Gtk.Button? float_button = null;
    private Gtk.Button? promote_button = null;
    private Gtk.Button? rotate_button = null;
    private Gtk.Button? rotate_back_button = null;
    private Gtk.Button? help_button = null;

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
        keybinding_settings = new GLib.Settings (KEYBINDINGS_SCHEMA);

        display_icon = new Gtk.Image.from_icon_name ("view-grid-symbolic", Gtk.IconSize.MENU);

        visible = true;

        gala_client.availability_changed.connect ((available) => {
            refresh_ui ();
        });
        bsp_settings.changed.connect ((key) => {
            refresh_ui ();
        });
        behavior_settings.changed.connect ((key) => {
            refresh_ui ();
        });
        keybinding_settings.changed.connect ((key) => {
            refresh_ui ();
        });
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
        var content = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
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
        title_label.use_markup = true;
        title_label.label = "<b>BSP Tiling</b>";
        content.pack_start (title_label, false, false, 0);

        status_label = new Gtk.Label ("") {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        status_label.get_style_context ().add_class ("dim-label");
        content.pack_start (status_label, false, false, 0);

        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        content.pack_start (create_switch_row (
            "Enable BSP",
            "Turn tiling on or off globally",
            out bsp_enabled_switch
        ), false, false, 0);
        bsp_enabled_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bool current_state;
            gala_client.ensure_bsp_enabled (bsp_enabled_switch.active, out current_state);
            refresh_ui ();
        });

        content.pack_start (create_switch_row (
            "This Workspace",
            "Enable BSP for the active workspace and keep per-workspace state",
            out workspace_switch
        ), false, false, 0);
        workspace_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bool current_state;
            gala_client.ensure_active_workspace_enabled (workspace_switch.active, out current_state);
            refresh_ui ();
        });

        content.pack_start (create_switch_row (
            "Master Window",
            "Keep a dedicated master tile and place the remaining windows in the stack area",
            out master_enabled_switch
        ), false, false, 0);
        master_enabled_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bool current_state;
            if (!gala_client.set_master_enabled (master_enabled_switch.active, out current_state)) {
                bsp_settings.set_boolean ("master-enabled", master_enabled_switch.active);
            }

            refresh_ui ();
        });

        content.pack_start (create_combo_row (
            "Master Side",
            "Choose which side of the screen the master tile uses",
            out master_side_combo
        ), false, false, 0);
        master_side_combo.append ("left", "Left");
        master_side_combo.append ("right", "Right");
        master_side_combo.changed.connect (() => {
            if (syncing_controls) {
                return;
            }

            var active_id = master_side_combo.get_active_id ();
            if (active_id == null || active_id == "") {
                return;
            }

            string applied_side;
            if (!gala_client.set_master_side (active_id, out applied_side)) {
                bsp_settings.set_string ("master-side", active_id);
            }

            refresh_ui ();
        });

        content.pack_start (create_spin_row (
            "Inner Gap",
            "Gap between tiled windows",
            out inner_gap_spin
        ), false, false, 0);
        inner_gap_spin.update_policy = Gtk.SpinButtonUpdatePolicy.IF_VALID;
        inner_gap_spin.value_changed.connect (() => {
            if (syncing_controls) {
                return;
            }

            apply_gap_value (inner_gap_spin, true);
        });
        inner_gap_spin.activate.connect (() => {
            if (!syncing_controls) {
                apply_gap_value (inner_gap_spin, true);
            }
        });
        inner_gap_spin.focus_out_event.connect ((event) => {
            if (!syncing_controls) {
                apply_gap_value (inner_gap_spin, true);
            }

            return false;
        });

        content.pack_start (create_spin_row (
            "Outer Gap",
            "Gap between the layout and the screen edge",
            out outer_gap_spin
        ), false, false, 0);
        outer_gap_spin.update_policy = Gtk.SpinButtonUpdatePolicy.IF_VALID;
        outer_gap_spin.value_changed.connect (() => {
            if (syncing_controls) {
                return;
            }

            apply_gap_value (outer_gap_spin, false);
        });
        outer_gap_spin.activate.connect (() => {
            if (!syncing_controls) {
                apply_gap_value (outer_gap_spin, false);
            }
        });
        outer_gap_spin.focus_out_event.connect ((event) => {
            if (!syncing_controls) {
                apply_gap_value (outer_gap_spin, false);
            }

            return false;
        });

        content.pack_start (create_switch_row (
            "Live Reorder",
            "Rebuild the BSP tree while dragging tiled windows",
            out live_reorder_switch
        ), false, false, 0);
        live_reorder_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            bsp_settings.set_boolean ("live-reorder-on-drag", live_reorder_switch.active);
        });

        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        content.pack_start (create_switch_row (
            "Focus Follows Mouse",
            "Focus windows when the pointer enters them",
            out focus_follows_mouse_switch
        ), false, false, 0);
        focus_follows_mouse_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            behavior_settings.set_boolean ("focus-follows-mouse", focus_follows_mouse_switch.active);
        });

        content.pack_start (create_switch_row (
            "Mouse Follows Focus",
            "Warp the pointer to the newly focused window",
            out mouse_follows_focus_switch
        ), false, false, 0);
        mouse_follows_focus_switch.notify["active"].connect (() => {
            if (syncing_controls) {
                return;
            }

            behavior_settings.set_boolean ("mouse-follows-focus", mouse_follows_focus_switch.active);
        });

        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        var actions_label = new Gtk.Label ("Window Actions") {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        actions_label.use_markup = true;
        actions_label.label = "<b>Window Actions</b>";
        content.pack_start (actions_label, false, false, 0);

        var actions_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            homogeneous = true
        };
        float_button = create_action_button ("Float", () => {
            gala_client.toggle_focused_window_floating ();
            refresh_ui ();
        });
        actions_box.pack_start (float_button, true, true, 0);

        promote_button = create_action_button ("Promote", () => {
            gala_client.promote_focused_window ();
            refresh_ui ();
        });
        actions_box.pack_start (promote_button, true, true, 0);

        rotate_button = create_action_button ("Rotate", () => {
            gala_client.rotate_group_forward ();
            refresh_ui ();
        });
        actions_box.pack_start (rotate_button, true, true, 0);

        rotate_back_button = create_action_button ("Rotate Back", () => {
            gala_client.rotate_group_backward ();
            refresh_ui ();
        });
        actions_box.pack_start (rotate_back_button, true, true, 0);
        content.pack_start (actions_box, false, false, 0);

        content.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

        help_button = new Gtk.Button.with_label ("Keyboard Shortcuts and Help...");
        help_button.halign = Gtk.Align.FILL;
        help_button.clicked.connect (() => {
            if (help_overlay == null) {
                help_overlay = new HelpOverlay (keybinding_settings);
            }

            help_overlay.present ();
        });
        content.pack_start (help_button, false, false, 0);

        var scrolled = new Gtk.ScrolledWindow (null, null) {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            min_content_width = 340
        };
        scrolled.set_policy (Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC);
        scrolled.set_propagate_natural_height (true);
        scrolled.add (content);

        popover_widget = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        popover_widget.pack_start (scrolled, true, true, 0);
        popover_widget.show_all ();
    }

    private Gtk.Widget create_switch_row (string title, string subtitle, out Gtk.Switch switch_widget) {
        var title_label = new Gtk.Label (title) {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.use_markup = true;
        title_label.label = "<b>%s</b>".printf (GLib.Markup.escape_text (title));

        var subtitle_label = new Gtk.Label (subtitle) {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        subtitle_label.get_style_context ().add_class ("dim-label");

        var labels_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true
        };
        labels_box.pack_start (title_label, false, false, 0);
        labels_box.pack_start (subtitle_label, false, false, 0);

        switch_widget = new Gtk.Switch () {
            halign = Gtk.Align.END,
            valign = Gtk.Align.CENTER
        };

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.pack_start (labels_box, true, true, 0);
        row.pack_start (switch_widget, false, false, 0);
        return row;
    }

    private Gtk.Widget create_spin_row (string title, string subtitle, out Gtk.SpinButton spin_button) {
        var title_label = new Gtk.Label (title) {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.use_markup = true;
        title_label.label = "<b>%s</b>".printf (GLib.Markup.escape_text (title));

        var subtitle_label = new Gtk.Label (subtitle) {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        subtitle_label.get_style_context ().add_class ("dim-label");

        var labels_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true
        };
        labels_box.pack_start (title_label, false, false, 0);
        labels_box.pack_start (subtitle_label, false, false, 0);

        spin_button = new Gtk.SpinButton.with_range (0, 96, 1) {
            halign = Gtk.Align.END,
            valign = Gtk.Align.CENTER,
            width_chars = 4,
            numeric = true
        };

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.pack_start (labels_box, true, true, 0);
        row.pack_start (spin_button, false, false, 0);
        return row;
    }

    private Gtk.Widget create_combo_row (string title, string subtitle, out Gtk.ComboBoxText combo) {
        var title_label = new Gtk.Label (title) {
            halign = Gtk.Align.START,
            xalign = 0.0f
        };
        title_label.use_markup = true;
        title_label.label = "<b>%s</b>".printf (GLib.Markup.escape_text (title));

        var subtitle_label = new Gtk.Label (subtitle) {
            halign = Gtk.Align.START,
            xalign = 0.0f,
            wrap = true
        };
        subtitle_label.get_style_context ().add_class ("dim-label");

        var labels_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 2) {
            hexpand = true
        };
        labels_box.pack_start (title_label, false, false, 0);
        labels_box.pack_start (subtitle_label, false, false, 0);

        combo = new Gtk.ComboBoxText ();
        combo.halign = Gtk.Align.END;
        combo.valign = Gtk.Align.CENTER;

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        row.pack_start (labels_box, true, true, 0);
        row.pack_start (combo, false, false, 0);
        return row;
    }

    private void apply_gap_value (Gtk.SpinButton spin_button, bool inner_gap) {
        var requested_value = spin_button.get_value_as_int ();
        int applied_value;

        if (inner_gap) {
            if (!gala_client.set_inner_gap (requested_value, out applied_value)) {
                bsp_settings.set_int ("inner-gap", requested_value);
                applied_value = requested_value;
            }
        } else {
            if (!gala_client.set_outer_gap (requested_value, out applied_value)) {
                bsp_settings.set_int ("outer-gap", requested_value);
                applied_value = requested_value;
            }
        }

        if (!spin_button.has_focus) {
            syncing_controls = true;
            spin_button.set_value ((double) applied_value);
            syncing_controls = false;
        }
    }

    private Gtk.Button create_action_button (string title, owned ActionCallback callback) {
        var button = new Gtk.Button.with_label (title);
        button.relief = Gtk.ReliefStyle.NONE;
        button.clicked.connect (() => {
            callback ();
        });

        return button;
    }

    private void refresh_ui () {
        var active_scope = "global";
        var global_enabled = bsp_settings.get_boolean ("enabled");
        var active_workspace_enabled = global_enabled;
        var master_enabled = bsp_settings.get_boolean ("master-enabled");
        var master_side = bsp_settings.get_string ("master-side");
        var inner_gap = bsp_settings.get_int ("inner-gap");
        var outer_gap = bsp_settings.get_int ("outer-gap");
        var has_gala_state = false;

        BspState gala_state;
        if (gala_client.try_get_state (out gala_state)) {
            active_scope = gala_state.scope;
            global_enabled = gala_state.enabled;
            active_workspace_enabled = gala_state.active_workspace_enabled;
            master_enabled = gala_state.master_enabled;
            master_side = gala_state.master_side;
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
                ? "Mode: %s\nCurrent workspace: %s\nMaster: %s (%s)\nInner gap: %d px\nOuter gap: %d px".printf (
                    mode_text,
                    active_workspace_enabled ? "enabled" : "disabled",
                    master_enabled ? "enabled" : "disabled",
                    master_side,
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

        if (master_enabled_switch != null) {
            master_enabled_switch.active = master_enabled;
            master_enabled_switch.sensitive = true;
        }

        if (master_side_combo != null) {
            master_side_combo.set_active_id (master_side == "right" ? "right" : "left");
            master_side_combo.sensitive = master_enabled;
        }

        if (inner_gap_spin != null) {
            if (!inner_gap_spin.has_focus) {
                inner_gap_spin.set_value ((double) inner_gap);
            }
        }

        if (outer_gap_spin != null) {
            if (!outer_gap_spin.has_focus) {
                outer_gap_spin.set_value ((double) outer_gap);
            }
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

        if (help_button != null) {
            help_button.sensitive = true;
        }

        display_icon.opacity = active_workspace_enabled ? 1.0 : 0.55;
        display_icon.tooltip_text = "BSP: %s, master %s (%s), inner gap %d px, outer gap %d px".printf (
            active_workspace_enabled ? "enabled" : "disabled",
            master_enabled ? "enabled" : "disabled",
            master_side,
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
