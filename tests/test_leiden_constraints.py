import random
import unittest

from igraph import Graph, InternalError, set_random_number_generator


class LeidenCountConstraintTests(unittest.TestCase):
    def setUp(self):
        set_random_number_generator(random.Random(0))
        self.addCleanup(set_random_number_generator, random)
        self.graph = Graph.Famous("Zachary")

    def occupied(self, result):
        if hasattr(result, "membership") and result.membership and isinstance(
            result.membership[0], list
        ):
            return len({c for row in result.membership for c in row})
        return len(set(result.membership))

    def test_upper_bound_holds_for_partitions_and_covers(self):
        for max_memberships in (1, 3):
            for local_move_only in (True, False):
                for bound in (1, 2, 5):
                    result = self.graph.community_leiden(
                        objective_function="CPM",
                        resolution=0.3,
                        max_memberships=max_memberships,
                        n_iterations=-1,
                        local_move_only=local_move_only,
                        max_total_communities=bound,
                    )
                    self.assertLessEqual(self.occupied(result), bound)

    def test_exact_count_holds_for_partitions_and_covers(self):
        for max_memberships in (1, 3):
            for local_move_only in (True, False):
                for count in (1, 3, 7):
                    result = self.graph.community_leiden(
                        objective_function="CPM",
                        resolution=0.05,
                        max_memberships=max_memberships,
                        n_iterations=-1,
                        local_move_only=local_move_only,
                        n_communities=count,
                    )
                    self.assertEqual(self.occupied(result), count)

    def test_exact_cover_count_may_exceed_vertex_count(self):
        graph = Graph([(0, 1), (1, 2), (2, 3)])
        result = graph.community_leiden(
            objective_function="CPM",
            resolution=0.5,
            max_memberships=2,
            n_iterations=-1,
            n_communities=6,
        )
        self.assertEqual(self.occupied(result), 6)
        self.assertTrue(all(1 <= len(row) <= 2 for row in result.membership))

    def test_unset_constraints_leave_results_unchanged(self):
        for max_memberships in (1, 2):
            set_random_number_generator(random.Random(5))
            a = self.graph.community_leiden(
                objective_function="CPM", resolution=0.2,
                max_memberships=max_memberships, n_iterations=-1,
            )
            set_random_number_generator(random.Random(5))
            b = self.graph.community_leiden(
                objective_function="CPM", resolution=0.2,
                max_memberships=max_memberships, n_iterations=-1,
                max_total_communities=None, n_communities=None,
            )
            self.assertEqual(a.membership, b.membership)

    def test_invalid_constraints_are_rejected(self):
        leiden = self.graph.community_leiden
        with self.assertRaises(ValueError):
            leiden(objective_function="CPM", max_total_communities=0)
        with self.assertRaises(ValueError):
            leiden(objective_function="CPM", n_communities=0)
        with self.assertRaises(ValueError):
            leiden(objective_function="CPM", n_communities=True)
        with self.assertRaises(ValueError):
            leiden(objective_function="CPM", max_total_communities=2, n_communities=3)
        with self.assertRaises(ValueError):
            leiden(objective_function="CPM", max_memberships=2, n_communities=2,
                   debug_trace=True)
        with self.assertRaises(InternalError):
            leiden(objective_function="CPM", n_communities=35)
        with self.assertRaises(InternalError):
            leiden(objective_function="CPM", max_memberships=2, n_communities=69)

    def test_violating_start_is_rejected_not_repaired(self):
        singleton = list(range(self.graph.vcount()))
        with self.assertRaises(InternalError):
            self.graph.community_leiden(
                objective_function="CPM", initial_membership=singleton,
                max_total_communities=3,
            )
        rows = [[v] for v in range(self.graph.vcount())]
        with self.assertRaises(InternalError):
            self.graph.community_leiden(
                objective_function="CPM", max_memberships=2,
                initial_membership=rows, n_communities=3,
            )


if __name__ == "__main__":
    unittest.main()
