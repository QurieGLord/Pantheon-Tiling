namespace Gala {
    private class BspNode : Object {
        public weak BspNode? parent = null;
        public BspNode? left = null;
        public BspNode? right = null;
        public Object? tile = null;
        public double split_ratio = 0.5;
        public bool split_horizontal = true;

        public bool is_leaf () {
            return left == null && right == null;
        }
    }

    private class BspMinSize : Object {
        public int width;
        public int height;

        public BspMinSize (int width = 1, int height = 1) {
            this.width = int.max (1, width);
            this.height = int.max (1, height);
        }
    }

    public class BspLayout : Object {
        public delegate void LeafRectFunc (Object tile, Mtk.Rectangle rect);
        public delegate void LeafMinSizeFunc (Object tile, out int min_width, out int min_height);

        private BspNode? root = null;
        private Gee.HashMap<Object, BspNode> leaves = new Gee.HashMap<Object, BspNode> ();
        private Gee.ArrayList<Object> ordered_tiles = new Gee.ArrayList<Object> ();
        private bool master_enabled = true;
        private bool master_left = true;

        public uint size {
            get {
                return (uint) ordered_tiles.size;
            }
        }

        public bool is_empty {
            get {
                return ordered_tiles.size == 0;
            }
        }

        public void set_master_options (bool enabled, bool left = true) {
            if (master_enabled == enabled && master_left == left) {
                return;
            }

            master_enabled = enabled;
            master_left = left;
            rebuild_from_order (get_tiles_in_order ());
        }

        public bool get_master_enabled () {
            return master_enabled;
        }

        public bool get_master_left () {
            return master_left;
        }

        public bool contains (Object tile) {
            return leaves.has_key (tile);
        }

        public Object? get_any_tile () {
            return ordered_tiles.size > 0 ? ordered_tiles[0] : null;
        }

        public Gee.ArrayList<Object> get_tiles_in_order () {
            var tiles = new Gee.ArrayList<Object> ();
            foreach (var tile in ordered_tiles) {
                tiles.add (tile);
            }
            return tiles;
        }

        public BspLayout copy () {
            var layout = new BspLayout ();
            layout.master_enabled = master_enabled;
            layout.master_left = master_left;
            layout.rebuild_from_order (ordered_tiles);
            return layout;
        }

        public void insert (Object tile, Object? split_target = null) {
            if (contains (tile)) {
                return;
            }

            var tiles = get_tiles_in_order ();
            var insert_index = tiles.size;

            if (split_target != null) {
                var target_index = tiles.index_of (split_target);
                if (target_index >= 0) {
                    insert_index = target_index + 1;
                }
            }

            tiles.insert (insert_index, tile);
            rebuild_from_order (tiles);
        }

        public void remove (Object tile) {
            if (!contains (tile)) {
                return;
            }

            var remaining_tiles = get_tiles_in_order ();
            for (int i = remaining_tiles.size - 1; i >= 0; i--) {
                if (remaining_tiles[i] == tile) {
                    remaining_tiles.remove_at (i);
                }
            }

            rebuild_from_order (remaining_tiles);
        }

        public bool swap (Object first_tile, Object second_tile) {
            if (first_tile == second_tile) {
                return false;
            }

            var tiles = get_tiles_in_order ();
            var first_index = tiles.index_of (first_tile);
            var second_index = tiles.index_of (second_tile);
            if (first_index < 0 || second_index < 0) {
                return false;
            }

            var tmp = tiles[first_index];
            tiles[first_index] = tiles[second_index];
            tiles[second_index] = tmp;
            rebuild_from_order (tiles);
            return true;
        }

        public bool move (Object tile, Object target_tile) {
            if (tile == target_tile) {
                return false;
            }

            var tiles = get_tiles_in_order ();
            var tile_index = tiles.index_of (tile);
            var target_index = tiles.index_of (target_tile);
            if (tile_index < 0 || target_index < 0) {
                return false;
            }

            tiles.remove_at (tile_index);
            target_index = target_index.clamp (0, tiles.size);
            tiles.insert (target_index, tile);
            rebuild_from_order (tiles);
            return true;
        }

        public bool promote (Object tile) {
            var tiles = get_tiles_in_order ();
            var tile_index = tiles.index_of (tile);
            if (tile_index <= 0) {
                return false;
            }

            tiles.remove_at (tile_index);
            tiles.insert (0, tile);
            rebuild_from_order (tiles);
            return true;
        }

        public bool rotate (bool forward = true) {
            var tiles = get_tiles_in_order ();
            if (tiles.size < 2) {
                return false;
            }

            if (forward) {
                var first_tile = tiles.remove_at (0);
                tiles.add (first_tile);
            } else {
                var last_tile = tiles.remove_at (tiles.size - 1);
                tiles.insert (0, last_tile);
            }

            rebuild_from_order (tiles);
            return true;
        }

        public void foreach_leaf_rect (Mtk.Rectangle area, LeafRectFunc func, LeafMinSizeFunc? min_size_func = null) {
            if (root == null || area.width <= 0 || area.height <= 0) {
                return;
            }

            apply_layout (root, area, func, min_size_func);
        }

        private void rebuild_from_order (Gee.List<Object> tiles) {
            root = null;
            leaves.clear ();
            ordered_tiles.clear ();

            foreach (var tile in tiles) {
                ordered_tiles.add (tile);
            }

            if (ordered_tiles.size == 0) {
                return;
            }

            if (master_enabled && ordered_tiles.size > 1) {
                root = build_master_tree ();
            } else {
                root = build_balanced_tree (ordered_tiles, 0, ordered_tiles.size, true, null);
            }
        }

        private BspNode create_leaf (Object tile, BspNode? parent) {
            var leaf = new BspNode ();
            leaf.parent = parent;
            leaf.tile = tile;
            leaves[tile] = leaf;
            return leaf;
        }

        private BspNode build_master_tree () {
            var node = new BspNode ();
            node.split_horizontal = true;
            node.split_ratio = 0.5;

            var master_leaf = create_leaf (ordered_tiles[0], node);
            var stack_root = build_stack_tree (ordered_tiles, 1, ordered_tiles.size - 1, false, node);

            if (master_left) {
                node.left = master_leaf;
                node.right = stack_root;
            } else {
                node.left = stack_root;
                node.right = master_leaf;
            }

            return node;
        }

        private BspNode? build_stack_tree (Gee.List<Object> tiles, int start, int count, bool split_horizontal, BspNode? parent) {
            if (count <= 0) {
                return null;
            }

            if (count == 1) {
                return create_leaf (tiles[start], parent);
            }

            var node = new BspNode ();
            node.parent = parent;
            node.split_horizontal = split_horizontal;
            node.split_ratio = 0.5;
            node.left = create_leaf (tiles[start], node);
            node.right = build_stack_tree (tiles, start + 1, count - 1, !split_horizontal, node);
            return node;
        }

        private BspNode? build_balanced_tree (Gee.List<Object> tiles, int start, int count, bool split_horizontal, BspNode? parent) {
            if (count <= 0) {
                return null;
            }

            if (count == 1) {
                return create_leaf (tiles[start], parent);
            }

            var node = new BspNode ();
            node.parent = parent;
            node.split_horizontal = split_horizontal;
            node.split_ratio = 0.5;

            var first_count = int.max (1, count / 2);
            var second_count = count - first_count;
            node.left = build_balanced_tree (tiles, start, first_count, !split_horizontal, node);
            node.right = build_balanced_tree (tiles, start + first_count, second_count, !split_horizontal, node);
            return node;
        }

        private int clamp_split_size (int size, double ratio) {
            if (size <= 1) {
                return size;
            }

            var split = (int) Math.round (size * ratio);
            split = int.max (1, split);
            split = int.min (size - 1, split);
            return split;
        }

        private BspMinSize get_subtree_min_size (BspNode? node, LeafMinSizeFunc? min_size_func) {
            if (node == null) {
                return new BspMinSize ();
            }

            if (node.is_leaf ()) {
                if (node.tile == null) {
                    return new BspMinSize ();
                }

                var min_width = 1;
                var min_height = 1;
                if (min_size_func != null) {
                    min_size_func (node.tile, out min_width, out min_height);
                }

                return new BspMinSize (min_width, min_height);
            }

            var left_min = get_subtree_min_size (node.left, min_size_func);
            var right_min = get_subtree_min_size (node.right, min_size_func);

            if (node.split_horizontal) {
                return new BspMinSize (
                    left_min.width + right_min.width,
                    int.max (left_min.height, right_min.height)
                );
            }

            return new BspMinSize (
                int.max (left_min.width, right_min.width),
                left_min.height + right_min.height
            );
        }

        private void apply_layout (BspNode node, Mtk.Rectangle rect, LeafRectFunc func, LeafMinSizeFunc? min_size_func) {
            if (node.is_leaf ()) {
                if (node.tile != null) {
                    func (node.tile, rect);
                }

                return;
            }

            Mtk.Rectangle first = { rect.x, rect.y, rect.width, rect.height };
            Mtk.Rectangle second = { rect.x, rect.y, rect.width, rect.height };
            var left_min = get_subtree_min_size (node.left, min_size_func);
            var right_min = get_subtree_min_size (node.right, min_size_func);

            if (node.split_horizontal) {
                var first_width = clamp_split_size (rect.width, node.split_ratio);
                if (left_min.width + right_min.width <= rect.width) {
                    first_width = int.max (left_min.width, first_width);
                    first_width = int.min (rect.width - right_min.width, first_width);
                }

                first.width = first_width;
                second.x += first_width;
                second.width -= first_width;
            } else {
                var first_height = clamp_split_size (rect.height, node.split_ratio);
                if (left_min.height + right_min.height <= rect.height) {
                    first_height = int.max (left_min.height, first_height);
                    first_height = int.min (rect.height - right_min.height, first_height);
                }

                first.height = first_height;
                second.y += first_height;
                second.height -= first_height;
            }

            if (node.left != null) {
                apply_layout (node.left, first, func, min_size_func);
            }

            if (node.right != null) {
                apply_layout (node.right, second, func, min_size_func);
            }
        }
    }
}
