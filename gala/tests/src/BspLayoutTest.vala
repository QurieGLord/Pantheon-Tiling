public class MockTile : Object {
    public string name { get; construct; }
    public Mtk.Rectangle rect { get; set; }
    public int min_width { get; set; default = 1; }
    public int min_height { get; set; default = 1; }

    public MockTile (string name) {
        Object (name: name);
    }
}

public class Gala.BspLayoutTest : TestCase {
    public BspLayoutTest () {
        Object (name: "BspLayout");
    }

    construct {
        add_test ("split geometry", test_split_geometry);
        add_test ("remove rebuilds canonical layout", test_remove_rebuilds_canonical_layout);
        add_test ("move rebuilds canonical order", test_move_rebuilds_canonical_order);
        add_test ("promote moves tile to master slot", test_promote_moves_tile_to_master_slot);
        add_test ("rotate forward cycles canonical order", test_rotate_forward_cycles_canonical_order);
        add_test ("minimum sizes influence constrained layout", test_minimum_sizes_influence_constrained_layout);
        add_test ("swap keeps tree structure", test_swap_keeps_tree_structure);
        add_test ("master can move to the right", test_master_can_move_to_the_right);
        add_test ("layout can disable the dedicated master tile", test_layout_can_disable_master_tile);
    }

    private void test_split_geometry () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (first.rect.x, EQ, 0);
        assert_cmpint (first.rect.y, EQ, 0);
        assert_cmpint (first.rect.width, EQ, 50);
        assert_cmpint (first.rect.height, EQ, 100);

        assert_cmpint (second.rect.x, EQ, 50);
        assert_cmpint (second.rect.y, EQ, 0);
        assert_cmpint (second.rect.width, EQ, 50);
        assert_cmpint (second.rect.height, EQ, 50);

        assert_cmpint (third.rect.x, EQ, 50);
        assert_cmpint (third.rect.y, EQ, 50);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 50);
    }

    private void test_remove_rebuilds_canonical_layout () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");
        var fourth = new MockTile ("fourth");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);
        layout.insert (fourth, third);
        layout.remove (first);

        assert_cmpint ((int) layout.size, EQ, 3);

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (second.rect.x, EQ, 0);
        assert_cmpint (second.rect.y, EQ, 0);
        assert_cmpint (second.rect.width, EQ, 50);
        assert_cmpint (second.rect.height, EQ, 100);

        assert_cmpint (third.rect.x, EQ, 50);
        assert_cmpint (third.rect.y, EQ, 0);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 50);

        assert_cmpint (fourth.rect.x, EQ, 50);
        assert_cmpint (fourth.rect.y, EQ, 50);
        assert_cmpint (fourth.rect.width, EQ, 50);
        assert_cmpint (fourth.rect.height, EQ, 50);

        var ordered_tiles = layout.get_tiles_in_order ();
        assert_cmpint (ordered_tiles.size, EQ, 3);
        assert_true (((MockTile) ordered_tiles[0]).name == "second");
        assert_true (((MockTile) ordered_tiles[1]).name == "third");
        assert_true (((MockTile) ordered_tiles[2]).name == "fourth");
    }

    private void test_swap_keeps_tree_structure () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        assert_true (layout.swap (first, third));

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (first.rect.x, EQ, 50);
        assert_cmpint (first.rect.y, EQ, 50);
        assert_cmpint (first.rect.width, EQ, 50);
        assert_cmpint (first.rect.height, EQ, 50);

        assert_cmpint (third.rect.x, EQ, 0);
        assert_cmpint (third.rect.y, EQ, 0);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 100);
    }

    private void test_move_rebuilds_canonical_order () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        assert_true (layout.move (third, first));

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (third.rect.x, EQ, 0);
        assert_cmpint (third.rect.y, EQ, 0);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 100);

        assert_cmpint (first.rect.x, EQ, 50);
        assert_cmpint (first.rect.y, EQ, 0);
        assert_cmpint (first.rect.width, EQ, 50);
        assert_cmpint (first.rect.height, EQ, 50);

        assert_cmpint (second.rect.x, EQ, 50);
        assert_cmpint (second.rect.y, EQ, 50);
        assert_cmpint (second.rect.width, EQ, 50);
        assert_cmpint (second.rect.height, EQ, 50);

        var ordered_tiles = layout.get_tiles_in_order ();
        assert_cmpint (ordered_tiles.size, EQ, 3);
        assert_true (((MockTile) ordered_tiles[0]).name == "third");
        assert_true (((MockTile) ordered_tiles[1]).name == "first");
        assert_true (((MockTile) ordered_tiles[2]).name == "second");
    }

    private void test_promote_moves_tile_to_master_slot () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        assert_true (layout.promote (third));

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (third.rect.x, EQ, 0);
        assert_cmpint (third.rect.y, EQ, 0);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 100);
    }

    private void test_rotate_forward_cycles_canonical_order () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        assert_true (layout.rotate (true));

        var ordered_tiles = layout.get_tiles_in_order ();
        assert_cmpint (ordered_tiles.size, EQ, 3);
        assert_true (((MockTile) ordered_tiles[0]).name == "second");
        assert_true (((MockTile) ordered_tiles[1]).name == "third");
        assert_true (((MockTile) ordered_tiles[2]).name == "first");
    }

    private void test_minimum_sizes_influence_constrained_layout () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third") {
            min_width = 204
        };
        var fourth = new MockTile ("fourth") {
            min_width = 204
        };

        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);
        layout.insert (fourth, third);

        Mtk.Rectangle area = { 0, 0, 800, 600 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        }, (tile, out min_width, out min_height) => {
            var mock_tile = (MockTile) tile;
            min_width = mock_tile.min_width;
            min_height = mock_tile.min_height;
        });

        assert_cmpint (first.rect.width, EQ, 392);
        assert_cmpint (second.rect.width, EQ, 408);
        assert_cmpint (third.rect.width, EQ, 204);
        assert_cmpint (fourth.rect.width, EQ, 204);
        assert_cmpint (fourth.rect.x, EQ, 596);
    }

    private void test_master_can_move_to_the_right () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");

        layout.set_master_options (true, false);
        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (first.rect.x, EQ, 50);
        assert_cmpint (first.rect.y, EQ, 0);
        assert_cmpint (first.rect.width, EQ, 50);
        assert_cmpint (first.rect.height, EQ, 100);

        assert_cmpint (second.rect.x, EQ, 0);
        assert_cmpint (second.rect.y, EQ, 0);
        assert_cmpint (second.rect.width, EQ, 50);
        assert_cmpint (second.rect.height, EQ, 50);

        assert_cmpint (third.rect.x, EQ, 0);
        assert_cmpint (third.rect.y, EQ, 50);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 50);
    }

    private void test_layout_can_disable_master_tile () {
        var layout = new BspLayout ();
        var first = new MockTile ("first");
        var second = new MockTile ("second");
        var third = new MockTile ("third");
        var fourth = new MockTile ("fourth");

        layout.set_master_options (false, true);
        layout.insert (first);
        layout.insert (second, first);
        layout.insert (third, second);
        layout.insert (fourth, third);

        Mtk.Rectangle area = { 0, 0, 100, 100 };
        layout.foreach_leaf_rect (area, (tile, rect) => {
            ((MockTile) tile).rect = rect;
        });

        assert_cmpint (first.rect.x, EQ, 0);
        assert_cmpint (first.rect.y, EQ, 0);
        assert_cmpint (first.rect.width, EQ, 50);
        assert_cmpint (first.rect.height, EQ, 50);

        assert_cmpint (second.rect.x, EQ, 0);
        assert_cmpint (second.rect.y, EQ, 50);
        assert_cmpint (second.rect.width, EQ, 50);
        assert_cmpint (second.rect.height, EQ, 50);

        assert_cmpint (third.rect.x, EQ, 50);
        assert_cmpint (third.rect.y, EQ, 0);
        assert_cmpint (third.rect.width, EQ, 50);
        assert_cmpint (third.rect.height, EQ, 50);

        assert_cmpint (fourth.rect.x, EQ, 50);
        assert_cmpint (fourth.rect.y, EQ, 50);
        assert_cmpint (fourth.rect.width, EQ, 50);
        assert_cmpint (fourth.rect.height, EQ, 50);
    }
}

public int main (string[] args) {
    return new Gala.BspLayoutTest ().run (args);
}
