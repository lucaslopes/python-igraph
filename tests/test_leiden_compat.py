"""Compatibility contract of Graph.community_leiden().

* The positional parameters and defaults are those of python-igraph 1.0.0,
  and a call that uses only them runs the igraph 1.0.0 algorithm
  (``igraph_community_leiden()``); extension controls are keyword-only.
* The compatibility matrix: partitions and covers, both values of
  ``allow_isolation`` and ``local_move_only``, zero/positive/negative
  budgets, fresh and supplied starts, unconstrained/at-most/exact counts,
  and each diagnostic level. Diagnostics never change the result.
* Every invalid cross-mode combination raises an error that names the
  conflicting option.
"""

import inspect
import itertools
import random
import unittest

from igraph import Graph, GraphBase, InternalError, set_random_number_generator


IGRAPH_1_0_0_PARAMETERS = [
    "graph", "objective_function", "weights", "resolution", "beta",
    "initial_membership", "n_iterations", "node_weights", "node_in_weights",
]
EXTENSION_PARAMETERS = [
    "max_memberships", "allow_isolation", "local_move_only",
    "max_total_communities", "n_communities", "debug_trace",
]


def occupied(result, overlapping):
    if overlapping:
        return len({c for row in result.membership for c in row})
    return len(set(result.membership))


class LeidenCallShapeTests(unittest.TestCase):
    def setUp(self):
        set_random_number_generator(random.Random(0))
        self.addCleanup(set_random_number_generator, random)

    def test_signature_keeps_the_1_0_0_positional_shape(self):
        parameters = inspect.signature(Graph.community_leiden).parameters
        names = list(parameters)
        self.assertEqual(names[: len(IGRAPH_1_0_0_PARAMETERS)], IGRAPH_1_0_0_PARAMETERS)
        defaults = {name: parameters[name].default for name in IGRAPH_1_0_0_PARAMETERS[1:]}
        self.assertEqual(defaults, {
            "objective_function": "CPM", "weights": None, "resolution": 1.0,
            "beta": 0.01, "initial_membership": None, "n_iterations": 2,
            "node_weights": None, "node_in_weights": None,
        })
        for name in EXTENSION_PARAMETERS:
            self.assertIs(parameters[name].kind, inspect.Parameter.KEYWORD_ONLY, name)

    def test_positional_1_0_0_call(self):
        graph = Graph.Famous("Zachary")
        start = [v % 3 for v in range(graph.vcount())]
        set_random_number_generator(random.Random(4))
        positional = graph.community_leiden("CPM", None, 0.05, 0.01, start, 3)
        set_random_number_generator(random.Random(4))
        keywords = graph.community_leiden(
            objective_function="CPM", resolution=0.05, initial_membership=start,
            n_iterations=3,
        )
        self.assertEqual(positional.membership, keywords.membership)
        with self.assertRaises(TypeError):
            graph.community_leiden("CPM", None, 0.05, 0.01, start, 3, None, None, 2)

    def test_native_keyword_order_is_the_1_0_0_order(self):
        graph = Graph.Famous("Zachary")
        set_random_number_generator(random.Random(8))
        membership, quality = GraphBase.community_leiden(
            graph, None, None, None, 0.05, False, 0.01, None, 2
        )
        self.assertEqual(len(membership), graph.vcount())
        self.assertIsInstance(quality, float)

    def test_directed_in_weights_are_accepted(self):
        graph = Graph.Erdos_Renyi(n=30, m=90, directed=True)
        out_weights = graph.outdegree()
        in_weights = graph.indegree()
        clustering = graph.community_leiden(
            "modularity", node_weights=out_weights, node_in_weights=in_weights,
            n_iterations=-1,
        )
        self.assertEqual(len(clustering.membership), graph.vcount())

    def test_1_0_0_call_keeps_the_1_0_0_candidate_set(self):
        # With a negative resolution, the extended local mover completes the
        # candidate set with clusters that no neighbour belongs to and merges
        # the two components; the igraph 1.0.0 algorithm cannot.
        graph = Graph([(0, 1), (1, 2), (2, 0), (3, 4), (4, 5), (5, 3)])
        base = graph.community_leiden("CPM", resolution=-0.5, n_iterations=-1)
        self.assertGreaterEqual(len(set(base.membership)), 2)
        explicit_defaults = graph.community_leiden(
            "CPM", resolution=-0.5, n_iterations=-1, max_memberships=1,
            allow_isolation=True, local_move_only=False,
            max_total_communities=None, n_communities=None, debug_trace=False,
        )
        self.assertEqual(base.membership, explicit_defaults.membership)
        extended = graph.community_leiden(
            "CPM", resolution=-0.5, n_iterations=-1, debug_trace="counters"
        )
        self.assertEqual(len(set(extended.membership)), 1)

    def test_old_call_equals_extended_defaults_in_the_shared_domain(self):
        graph = Graph.Famous("Zachary")
        for seed in range(5):
            set_random_number_generator(random.Random(seed))
            base = graph.community_leiden("CPM", resolution=0.1, n_iterations=-1)
            set_random_number_generator(random.Random(seed))
            extended = graph.community_leiden(
                "CPM", resolution=0.1, n_iterations=-1, debug_trace="counters"
            )
            self.assertEqual(base.membership, extended.membership)
            self.assertEqual(base.quality, extended.quality)


class LeidenCompatibilityMatrixTests(unittest.TestCase):
    def setUp(self):
        set_random_number_generator(random.Random(0))
        self.addCleanup(set_random_number_generator, random)
        self.graph = Graph.Famous("Zachary")
        self.graph.es["weight"] = [1.0 + (e % 3) / 2 for e in range(self.graph.ecount())]

    def run_cell(self, seed, **kwargs):
        set_random_number_generator(random.Random(seed))
        return self.graph.community_leiden(
            objective_function="CPM", weights="weight", resolution=0.08, **kwargs
        )

    def test_matrix(self):
        n = self.graph.vcount()
        cells = 0
        for (
            max_memberships, allow_isolation, local_move_only, budget, supplied, count,
        ) in itertools.product(
            (1, 3), (True, False), (True, False), (0, 1, -1), (False, True),
            ("none", "at_most", "exact"),
        ):
            overlapping = max_memberships > 1
            limits = {}
            if count == "at_most":
                limits["max_total_communities"] = 5
            elif count == "exact":
                limits["n_communities"] = 4
            start = None
            if supplied:
                k = 4 if count != "none" else 6
                start = (
                    [sorted({v % k, (v + 1) % k}) if v % 2 == 0 else [v % k]
                     for v in range(n)]
                    if overlapping else [v % k for v in range(n)]
                )
            kwargs = dict(
                max_memberships=max_memberships, allow_isolation=allow_isolation,
                local_move_only=local_move_only, n_iterations=budget,
                initial_membership=start, **limits,
            )
            with self.subTest(**{k: v for k, v in kwargs.items() if k != "initial_membership"},
                              supplied=supplied):
                seed = 1000 + cells
                plain = self.run_cell(seed, **kwargs)
                full = self.run_cell(seed, debug_trace=True, **kwargs)
                compact = self.run_cell(seed, debug_trace="counters", **kwargs)
                self.assertEqual(plain.membership, full.membership)
                self.assertEqual(plain.membership, compact.membership)

                trace = full._params["debug_trace"]
                counters = trace["counters"]
                self.assertEqual(trace["schema_version"], 3)
                self.assertEqual(trace["mode"], "cover" if overlapping else "partition")
                self.assertEqual(counters["max_memberships"], max_memberships)
                self.assertEqual(
                    counters["visits"],
                    counters["accepted_moves"] + counters["rejected_visits"],
                )
                self.assertEqual(counters["move_rows"], len(trace["moves"]))
                self.assertEqual(counters["move_rows"], counters["accepted_moves"])
                self.assertEqual(counters["projection_rows"], len(trace["projections"]))
                if budget == 0:
                    self.assertEqual(counters["visits"], 0)
                if not overlapping or local_move_only:
                    self.assertEqual(trace["projections"], [])
                compact_counters = dict(compact._params["debug_trace"]["counters"])
                self.assertEqual(compact_counters.pop("move_rows"), 0)
                self.assertEqual(compact_counters.pop("projection_rows"), 0)
                for name, value in compact_counters.items():
                    self.assertEqual(value, counters[name], name)

                result_count = occupied(plain, overlapping)
                if count == "at_most":
                    self.assertLessEqual(result_count, 5)
                    self.assertTrue(all(m["occupied_after"] <= 5 for m in trace["moves"]))
                elif count == "exact":
                    self.assertEqual(result_count, 4)
                    self.assertTrue(all(m["occupied_after"] == 4 for m in trace["moves"]))
                for move in trace["moves"]:
                    self.assertLessEqual(move["abs_error"], move["tolerance"])
                    self.assertGreater(move["predicted_delta"], 0.0)
                cells += 1
        self.assertEqual(cells, 2 * 2 * 2 * 3 * 2 * 3)


class LeidenInvalidCombinationTests(unittest.TestCase):
    def setUp(self):
        self.graph = Graph.Famous("Zachary")

    def test_errors_name_the_conflicting_option(self):
        directed = Graph([(0, 1), (1, 2), (2, 0)], directed=True)
        looped = Graph([(0, 1), (1, 1)])
        cases = [
            (lambda: self.graph.community_leiden("modularity", max_memberships=2),
             ValueError, "objective_function"),
            (lambda: self.graph.community_leiden(
                node_in_weights=[1.0] * 34, max_memberships=2),
             ValueError, "node_in_weights"),
            (lambda: directed.community_leiden(max_memberships=2),
             ValueError, "max_memberships > 1.*undirected"),
            (lambda: looped.community_leiden(max_memberships=2),
             ValueError, "max_memberships > 1.*loopless"),
            (lambda: Graph(n=3).community_leiden(max_memberships=2),
             ValueError, "max_memberships > 1.*edge"),
            (lambda: self.graph.community_leiden(max_memberships=35),
             ValueError, "max_memberships must not exceed"),
            (lambda: self.graph.community_leiden(
                resolution=float("inf"), max_memberships=2),
             ValueError, "resolution.*max_memberships > 1"),
            (lambda: self.graph.community_leiden(beta=-1.0, max_memberships=2),
             ValueError, "beta.*max_memberships > 1"),
            (lambda: self.graph.community_leiden(max_memberships=0),
             ValueError, "max_memberships"),
            (lambda: self.graph.community_leiden(debug_trace="moves"),
             ValueError, "debug_trace"),
            (lambda: self.graph.community_leiden(max_total_communities=0),
             ValueError, "max_total_communities"),
            (lambda: self.graph.community_leiden(n_communities=-2),
             ValueError, "n_communities"),
            (lambda: self.graph.community_leiden(
                max_total_communities=2, n_communities=3),
             ValueError, "n_communities must not exceed max_total_communities"),
            (lambda: self.graph.community_leiden(max_memberships=2, only_local_moving=True),
             TypeError, "unexpected keyword"),
        ]
        for call, error, pattern in cases:
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(error, pattern):
                    call()

    def test_binding_errors_name_the_conflicting_option(self):
        with self.assertRaisesRegex(ValueError, "normalization.*max_memberships > 1"):
            GraphBase.community_leiden(
                self.graph, normalize_resolution=True, max_memberships=2
            )
        with self.assertRaisesRegex(ValueError, "node_in_weights.*max_memberships > 1"):
            GraphBase.community_leiden(
                self.graph, node_in_weights=[1.0] * 34, max_memberships=2
            )

    def test_native_domain_errors(self):
        weights = [1.0] * self.graph.ecount()
        weights[0] = -1.0
        with self.assertRaises(InternalError):
            self.graph.community_leiden(weights=weights, max_memberships=2)
        with self.assertRaises(InternalError):
            self.graph.community_leiden(node_weights=[-1.0] + [1.0] * 33, max_memberships=2)
        with self.assertRaises(InternalError):
            self.graph.community_leiden(n_communities=35)
        with self.assertRaises(InternalError):
            self.graph.community_leiden(max_memberships=2, n_communities=69)


if __name__ == "__main__":
    unittest.main()
