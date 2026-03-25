/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2024-2025 elementary, Inc. (https://elementary.io)
 *                         2012-2014 Tom Beckmann
 *                         2012-2014 Jacob Parker
 */

[DBus (name="org.pantheon.gala")]
public class Gala.DBus {
    private static DBus? instance;
    private static WindowManagerGala wm;

    [DBus (visible = false)]
    public static void init (WindowManagerGala _wm, NotificationsManager notifications_manager, ScreenshotManager screenshot_manager) {
        wm = _wm;

        Bus.own_name (
            SESSION, "io.elementary.gala", NONE, null,
            (connection, name) => {
                try {
                    connection.register_object ("/io/elementary/gala", WindowDragProvider.get_instance ());
                } catch (Error e) {
                    warning (e.message);
                }
            },
            on_name_lost
        );

        Bus.own_name (
            SESSION, "org.pantheon.gala", NONE, null,
            (connection, name) => {
                if (instance == null) {
                    instance = new DBus ();
                }

                try {
                    connection.register_object ("/org/pantheon/gala", instance);
                    connection.register_object ("/org/pantheon/gala/DesktopInterface", new DesktopIntegration (wm));
                } catch (Error e) {
                    warning (e.message);
                }
            },
            on_name_lost
        );

        Bus.own_name (
            SESSION, "org.gnome.Shell", NONE, null,
            (connection, name) => {
                try {
                    connection.register_object ("/org/gnome/Shell", new DBusAccelerator (wm.get_display (), notifications_manager));
                    connection.register_object ("/org/gnome/Shell/Screenshot", screenshot_manager);
                } catch (Error e) {
                    warning (e.message);
                }
            },
            on_name_lost
        );

        Bus.own_name (
            SESSION, "org.gnome.Shell.Screenshot", REPLACE, null,
            null,
            on_name_lost
        );

        Bus.own_name (
            SESSION, "org.gnome.SessionManager.EndSessionDialog", NONE, null,
            (connection, name) => {
                try {
                    connection.register_object ("/org/gnome/SessionManager/EndSessionDialog", SessionManager.init ());
                } catch (Error e) {
                    warning (e.message);
                }
            },
            on_name_lost
        );

        Bus.own_name (
            SESSION, "org.gnome.ScreenSaver", REPLACE, null,
            (connection, name) => {
                try {
                    connection.register_object ("/org/gnome/ScreenSaver", wm.screensaver);
                } catch (Error e) {
                    warning (e.message);
                }
            },
            on_name_lost
        );
    }

    private static void on_name_lost (GLib.DBusConnection connection, string name) {
        warning ("DBus: Lost name %s", name);
    }

    public void perform_action (ActionType type) throws DBusError, IOError {
        wm.perform_action (type);
    }

    public bool get_bsp_enabled () throws DBusError, IOError {
        return wm.bsp_tree.is_enabled ();
    }

    public string get_bsp_scope () throws DBusError, IOError {
        return wm.bsp_tree.get_scope ();
    }

    public bool get_bsp_enabled_for_active_workspace () throws DBusError, IOError {
        return wm.bsp_tree.is_enabled_for_active_workspace ();
    }

    public int get_bsp_inner_gap () throws DBusError, IOError {
        return wm.bsp_tree.get_inner_gap ();
    }

    public int get_bsp_outer_gap () throws DBusError, IOError {
        return wm.bsp_tree.get_outer_gap ();
    }

    public bool toggle_bsp_enabled () throws DBusError, IOError {
        return wm.bsp_tree.toggle_enabled ();
    }

    public bool toggle_bsp_active_workspace_enabled () throws DBusError, IOError {
        return wm.bsp_tree.toggle_active_workspace_enabled ();
    }

    public bool toggle_bsp_focused_window_floating () throws DBusError, IOError {
        return wm.bsp_tree.toggle_focused_window_floating ();
    }

    public bool promote_bsp_focused_window () throws DBusError, IOError {
        return wm.bsp_tree.promote_focused_window ();
    }

    public bool rotate_bsp_group_forward () throws DBusError, IOError {
        return wm.bsp_tree.rotate_focused_group (true);
    }

    public bool rotate_bsp_group_backward () throws DBusError, IOError {
        return wm.bsp_tree.rotate_focused_group (false);
    }

    public int increase_bsp_inner_gap () throws DBusError, IOError {
        return wm.bsp_tree.adjust_inner_gap (4);
    }

    public int decrease_bsp_inner_gap () throws DBusError, IOError {
        return wm.bsp_tree.adjust_inner_gap (-4);
    }

    public int increase_bsp_outer_gap () throws DBusError, IOError {
        return wm.bsp_tree.adjust_outer_gap (4);
    }

    public int decrease_bsp_outer_gap () throws DBusError, IOError {
        return wm.bsp_tree.adjust_outer_gap (-4);
    }
}
