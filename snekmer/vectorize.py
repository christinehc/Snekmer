"""vectorize: Create kmer vectors.

author: @christinehc

"""
import itertools
from collections import Counter
from typing import Generator, Set, Union

import numpy as np
from numpy.typing import NDArray
from snekmer.alphabets import ALPHABET, FULL_ALPHABETS, get_alphabet, get_alphabet_keys


# generate all possible kmer combinations
def _generate(alphabet: Union[str, int], k: int):
    for c in itertools.product(alphabet, repeat=k):
        yield "".join(c)


# iterator object for kmer basis set given alphabet and k
class KmerSet:
    def __init__(self, alphabet: Union[str, int], k: int):
        self.alphabet = alphabet
        self.k = k
        self._kmerlist = list(_generate(get_alphabet_keys(alphabet), k))

    @property
    def kmers(self):
        return iter(self._kmerlist)


# manually reduce alphabet
def reduce(
    sequence: str, alphabet: Union[str, int], mapping: dict = FULL_ALPHABETS
) -> str:
    """Reduce sequence into character space of specified alphabet.

    Parameters
    ----------
    sequence : str
        Input sequence.
    alphabet : Union[str, int]
        Alphabet name or number (see `snekmer.alphabet`).
    mapping : dict
        Defined mapping for alphabet (the default is FULL_ALPHABETS).

    Returns
    -------
    str
        Transformed sequence.

    """
    sequence = str(sequence).rstrip("*")
    alphabet_map: dict = get_alphabet(alphabet, mapping=mapping)
    return sequence.translate(sequence.maketrans(alphabet_map))


class KmerVec:
    def __init__(self, alphabet: Union[str, int], k: int):
        self.alphabet = alphabet
        self.k = k
        self.kmer_gen = None
        self.char_set = get_alphabet_keys(alphabet)
        self.vector = None
        self.kmer_set = KmerSet(alphabet, k)

    # iteratively get all kmers in a string
    def _kmer_gen(self, sequence: str) -> Generator[str, None, None]:
        """Generator object for segment in string format"""
        i = 0
        n = len(sequence) - self.k + 1

        # iterate thru sequence in blocks of length k
        while i < n:
            kmer = sequence[i : i + self.k]
            if set(kmer) <= self.char_set:
                yield kmer
            i += 1

    # not used: iterate using range() vs. while loop
    @staticmethod
    def _kmer_gen_str(sequence: str, k: int) -> Generator[str, None, None]:
        """Generator object for segment in string format"""
        for n in range(0, len(sequence) - k + 1):
            yield sequence[n : n + k]

    # generate kmer vectors with bag-of-words approach
    def vectorize(self, sequence: str) -> NDArray:
        """Transform sequence into representative kmer vector.

        Parameters
        ----------
        sequence : str
            Input sequence.

        Returns
        -------
        NDArray
            Vector representation of sequence as kmer counts vector.

        """
        N = len(self.char_set) ** self.k

        kmers = list(self._kmer_gen(sequence))
        kmer2count = Counter(kmers)

        # Convert to vector of counts
        vector = np.zeros(N)
        for i, word in enumerate(self.kmer_set.kmers):
            vector[i] += kmer2count[word]

        # Convert to frequencies
        # vector /= sum(kmer2count.values())

        return vector

    def reduce_vectorize(self, sequence: str) -> NDArray:
        """Simplify and vectorize sequence into reduced kmer vector.

        Parameters
        ----------
        sequence : str
            Input sequence.

        Returns
        -------
        NDArray
            Vector representation of sequence as reduced kmer vector.

        """
        N = len(self.char_set) ** self.k

        reduced = reduce(sequence, alphabet=self.alphabet, mapping=FULL_ALPHABETS)
        kmers = list(self._kmer_gen(reduced))
        kmer2count = Counter(kmers)

        # Convert to vector of counts
        vector = np.zeros(N)
        for i, word in enumerate(self.kmer_set.kmers):
            vector[i] += kmer2count[word]

        # Convert to frequencies
        # vector /= sum(kmer2count.values())

        return vector
