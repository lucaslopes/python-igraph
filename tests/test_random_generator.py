import random
import unittest

import igraph
from igraph import (
    Graph,
    get_random_number_generator,
    set_random_number_generator,
)


class RandomNumberGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(set_random_number_generator, get_random_number_generator())

    def test_default_generator_is_the_random_module(self):
        self.assertIs(get_random_number_generator(), random)

    def test_getter_returns_the_generator_that_was_set(self):
        generator = random.Random(42)
        set_random_number_generator(generator)
        self.assertIs(get_random_number_generator(), generator)

    def test_c_level_default_is_reported_as_none(self):
        set_random_number_generator(None)
        self.assertIsNone(get_random_number_generator())
        set_random_number_generator(random)
        self.assertIs(get_random_number_generator(), random)

    def test_restoring_the_returned_generator_restores_the_stream(self):
        previous = get_random_number_generator()
        set_random_number_generator(random.Random(7))
        first = Graph.Erdos_Renyi(n=30, p=0.2).get_edgelist()
        set_random_number_generator(previous)
        self.assertIs(get_random_number_generator(), previous)
        set_random_number_generator(random.Random(7))
        second = Graph.Erdos_Renyi(n=30, p=0.2).get_edgelist()
        self.assertEqual(first, second)

    def test_module_exports_the_getter(self):
        self.assertIn("get_random_number_generator", igraph.__all__)


if __name__ == "__main__":
    unittest.main()
