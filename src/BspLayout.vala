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

    public class BspLayout : Object {
        public delegate void LeafRectFunc (Object tile, Mtk.Rectangle rect);

        private BspNode? root = null;
        private Gee.HashMap<Object, BspNode> leaves = new Gee.HashMap<Object, BspNode> ();

        public uint size {
            get {
                return (uint) leaves.size;
            }
        }

        public bool is_empty {
            get {
                return leaves.size == 0;
            }
        }

        public bool contains (Object tile) {
            return leaves.has_key (tile);
        }

        public Object? get_any_tile () {
            var leaf = get_first_leaf (root);
            return leaf != null ? leaf.tile : null;
        }

        public Gee.ArrayList<Object> get_tiles_in_order () {
            var tiles = new Gee.ArrayList<Object> ();
            collect_tiles (root, tiles);
            return tiles;
        }

        public BspLayout copy () {
            var layout = new BspLayout ();
            layout.root = clone_node (root, null, layout.leaves);
            return layout;
        }

        public void insert (Object tile, Object? split_target = null) {
            if (contains (tile)) {
                return;
            }

            if (root == null) {
                root = new BspNode ();
                root.tile = tile;
                leaves[tile] = root;
                return;
            }

            var target_leaf = choose_target_leaf (split_target);
            if (target_leaf == null) {
                return;
            }

            unowned var existing_tile = target_leaf.tile;
            if (existing_tile == null) {
                return;
            }

            var depth = get_depth (target_leaf);

            target_leaf.tile = null;
            target_leaf.split_ratio = 0.5;
            target_leaf.split_horizontal = depth % 2 == 0;

            target_leaf.left = new BspNode ();
            target_leaf.left.parent = target_leaf;
            target_leaf.left.tile = existing_tile;

            target_leaf.right = new BspNode ();
            target_leaf.right.parent = target_leaf;
            target_leaf.right.tile = tile;

            leaves[existing_tile] = target_leaf.left;
            leaves[tile] = target_leaf.right;
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

            var first_node = leaves[first_tile];
            var second_node = leaves[second_tile];
            if (first_node == null || second_node == null) {
                return false;
            }

            first_node.tile = second_tile;
            second_node.tile = first_tile;
            leaves[first_tile] = second_node;
            leaves[second_tile] = first_node;
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

        public void foreach_leaf_rect (Mtk.Rectangle area, LeafRectFunc func) {
            if (root == null || area.width <= 0 || area.height <= 0) {
                return;
            }

            apply_layout (root, area, func);
        }

        private BspNode? choose_target_leaf (Object? split_target) {
            if (split_target != null) {
                var explicit_target = leaves[split_target];
                if (explicit_target != null) {
                    return explicit_target;
                }
            }

            return get_first_leaf (root);
        }

        private BspNode? get_first_leaf (BspNode? node) {
            if (node == null) {
                return null;
            }

            if (node.is_leaf ()) {
                return node;
            }

            var left_leaf = get_first_leaf (node.left);
            if (left_leaf != null) {
                return left_leaf;
            }

            return get_first_leaf (node.right);
        }

        private int get_depth (BspNode node) {
            var depth = 0;

            for (unowned var current = node.parent; current != null; current = current.parent) {
                depth++;
            }

            return depth;
        }

        private void collect_tiles (BspNode? node, Gee.ArrayList<Object> tiles) {
            if (node == null) {
                return;
            }

            if (node.is_leaf ()) {
                if (node.tile != null) {
                    tiles.add (node.tile);
                }

                return;
            }

            collect_tiles (node.left, tiles);
            collect_tiles (node.right, tiles);
        }

        private BspNode? clone_node (BspNode? node, BspNode? parent, Gee.HashMap<Object, BspNode> target_leaves) {
            if (node == null) {
                return null;
            }

            var clone = new BspNode ();
            clone.parent = parent;
            clone.tile = node.tile;
            clone.split_ratio = node.split_ratio;
            clone.split_horizontal = node.split_horizontal;

            if (clone.tile != null && node.is_leaf ()) {
                target_leaves[clone.tile] = clone;
            }

            clone.left = clone_node (node.left, clone, target_leaves);
            clone.right = clone_node (node.right, clone, target_leaves);
            return clone;
        }

        private void rebuild_from_order (Gee.List<Object> tiles) {
            root = null;
            leaves.clear ();

            Object? split_target = null;
            foreach (var tile in tiles) {
                insert (tile, split_target);
                split_target = tile;
            }
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

        private void apply_layout (BspNode node, Mtk.Rectangle rect, LeafRectFunc func) {
            if (node.is_leaf ()) {
                if (node.tile != null) {
                    func (node.tile, rect);
                }

                return;
            }

            Mtk.Rectangle first = { rect.x, rect.y, rect.width, rect.height };
            Mtk.Rectangle second = { rect.x, rect.y, rect.width, rect.height };

            if (node.split_horizontal) {
                var first_width = clamp_split_size (rect.width, node.split_ratio);
                first.width = first_width;
                second.x += first_width;
                second.width -= first_width;
            } else {
                var first_height = clamp_split_size (rect.height, node.split_ratio);
                first.height = first_height;
                second.y += first_height;
                second.height -= first_height;
            }

            if (node.left != null) {
                apply_layout (node.left, first, func);
            }

            if (node.right != null) {
                apply_layout (node.right, second, func);
            }
        }
    }
}
