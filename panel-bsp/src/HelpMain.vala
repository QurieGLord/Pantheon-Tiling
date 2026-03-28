namespace PanelBsp {
    public class HelpApplication : Gtk.Application {
        private HelpOverlay? overlay = null;

        public HelpApplication () {
            Object (
                application_id: "io.elementary.panel.bsp.help"
            );
        }

        protected override void activate () {
            if (overlay == null) {
                overlay = new HelpOverlay (
                    new GLib.Settings ("io.elementary.desktop.wm.keybindings"),
                    this
                );
            }

            overlay.present ();
        }
    }
}

int main (string[] args) {
    var app = new PanelBsp.HelpApplication ();
    return app.run (args);
}
