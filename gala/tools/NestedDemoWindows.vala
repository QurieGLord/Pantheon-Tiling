using Gtk;
using GLib;

private class NestedDemoController : Object {
    private int window_count;
    private uint pause_ms;
    private int next_window = 1;
    private int open_windows = 0;
    private MainLoop loop = new MainLoop ();
    private int start_index;

    public NestedDemoController (int window_count, uint pause_ms, int start_index) {
        this.window_count = window_count;
        this.pause_ms = pause_ms;
        this.start_index = start_index;
    }

    public int run () {
        if (window_count <= 0) {
            return 0;
        }

        open_next_window ();
        loop.run ();
        return 0;
    }

    private void open_next_window () {
        if (next_window > window_count) {
            return;
        }

        var index = next_window++;
        var window_number = start_index + index - 1;
        var window = new Gtk.Window () {
            title = "BSP Demo %d".printf (window_number),
            default_width = 560,
            default_height = 360
        };

        var frame = new Gtk.Box (Gtk.Orientation.VERTICAL, 16) {
            margin_top = 24,
            margin_bottom = 24,
            margin_start = 24,
            margin_end = 24
        };

        var title = new Gtk.Label ("Pantheon Gala BSP Demo") {
            xalign = 0.0f,
            wrap = true
        };
        title.add_css_class ("title-2");

        var subtitle = new Gtk.Label ("Window %d of %d".printf (window_number, start_index + window_count - 1)) {
            xalign = 0.0f
        };
        subtitle.add_css_class ("title-4");

        var body = new Gtk.Label (
            "This window was created by tools/NestedDemoWindows.vala.\n\n"
            + "Use it to verify that BSP tiling opens, splits, and reflows windows."
        ) {
            xalign = 0.0f,
            wrap = true
        };

        frame.append (title);
        frame.append (subtitle);
        frame.append (body);
        window.set_child (frame);

        open_windows++;
        window.close_request.connect (() => {
            open_windows--;

            if (open_windows == 0 && next_window > window_count) {
                loop.quit ();
            }

            return false;
        });

        window.present ();
        stdout.printf ("Opened demo window %d/%d\n", window_number, start_index + window_count - 1);
        stdout.flush ();

        if (index < window_count) {
            Timeout.add (pause_ms, () => {
                open_next_window ();
                return Source.REMOVE;
            });
        }
    }
}

public static int main (string[] args) {
    var window_count = 4;
    uint pause_ms = 1500;
    var start_index = 1;

    if (args.length > 1) {
        window_count = int.parse (args[1]);
    }

    if (args.length > 2) {
        pause_ms = (uint) int.parse (args[2]);
    }

    if (args.length > 3) {
        start_index = int.parse (args[3]);
    }

    Gtk.init ();
    return new NestedDemoController (window_count, pause_ms, start_index).run ();
}
