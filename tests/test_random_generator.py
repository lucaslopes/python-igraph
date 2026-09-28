import gc
import random
import unittest
import weakref

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

    def test_invalid_generator_releases_partial_state(self):
        for invalid_attribute in ("getrandbits", "randint", "random", "gauss"):
            with self.subTest(attribute=invalid_attribute):
                previous = get_random_number_generator()
                generator = random.Random(42)
                setattr(generator, invalid_attribute, None)
                reference = weakref.ref(generator)
                for _ in range(10):
                    with self.assertRaisesRegex(TypeError, "must be callable"):
                        set_random_number_generator(generator)
                self.assertIs(get_random_number_generator(), previous)
                del generator
                gc.collect()
                self.assertIsNone(reference())

    def test_missing_method_releases_partial_state(self):
        class IncompleteGenerator:
            def randint(self, lower, upper):
                return lower

        generator = IncompleteGenerator()
        reference = weakref.ref(generator)
        previous = get_random_number_generator()
        with self.assertRaises(AttributeError):
            set_random_number_generator(generator)
        self.assertIs(get_random_number_generator(), previous)
        del generator
        gc.collect()
        self.assertIsNone(reference())

    def test_optional_method_access_preserves_exceptions(self):
        class BrokenGenerator(random.Random):
            @property
            def getrandbits(self):
                raise RuntimeError("cannot load getrandbits")

        previous = get_random_number_generator()
        with self.assertRaisesRegex(RuntimeError, "cannot load getrandbits"):
            set_random_number_generator(BrokenGenerator(42))
        self.assertIs(get_random_number_generator(), previous)

    def test_optional_method_is_read_once(self):
        class CountingGenerator(random.Random):
            reads = 0

            @property
            def getrandbits(self):
                self.reads += 1
                return super().getrandbits

        generator = CountingGenerator(42)
        set_random_number_generator(generator)
        self.assertEqual(generator.reads, 1)

    def test_replacing_generator_releases_its_owned_references(self):
        generator = random.Random(42)
        reference = weakref.ref(generator)
        set_random_number_generator(generator)
        del generator
        self.assertIsNotNone(reference())
        set_random_number_generator(random)
        gc.collect()
        self.assertIsNone(reference())


if __name__ == "__main__":
    unittest.main()
