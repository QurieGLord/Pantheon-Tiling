int main (string[] args) {
    Gtk.init (ref args);

    var overlay = new PanelBsp.HelpOverlay ();
    overlay.present ();

    Gtk.main ();
    return 0;
}
