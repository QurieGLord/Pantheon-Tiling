namespace Gala {
    public class BspTilingConfig : Object {
        public int inner_gap { get; set; default = 0; }
        public int outer_gap { get; set; default = 0; }
        public int border_width { get; set; default = 0; }
        public string border_color { get; set; default = "#4c8bf5"; }
        public bool live_reorder_on_drag { get; set; default = true; }
    }
}
