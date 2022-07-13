"""kmerize.smk: Module for kmer vector generation.

author: @christinehc

"""


# include unzipping module
include: "process_input.smk"


# built-in imports
import itertools
import gzip
import json
import pickle
from datetime import datetime
from glob import glob
from os.path import basename, join

# external libraries
import numpy as np
import snekmer as skm
from Bio import SeqIO

# get input files
input_files = glob(join("input", "*"))
unzipped = [
    fa.rstrip(".gz")
    for fa, ext in itertools.product(input_files, ["fasta"])
    if fa.rstrip(".gz").endswith(f".{ext}")
]
zipped = [fa for fa in input_files if fa.endswith(".gz")]
UZS = [skm.utils.split_file_ext(f)[0] for f in zipped]
FAS = [skm.utils.split_file_ext(f)[0] for f in unzipped]

# map extensions to basename (basename.ext.gz -> {basename: ext})
UZ_MAP = {
    skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in zipped
}
FA_MAP = {
    skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in unzipped
}


rule vectorize:
    input:
        fasta=lambda wildcards: join(
            "input", f"{wildcards.nb}.{FA_MAP[wildcards.nb]}"
        ),
    output:
        data=join("output", "vector", "{nb}.npz"),
        kmerobj=join("output", "kmerize", "{nb}.kmers"),
    log:
        join("output", "kmerize", "log", "{nb}.log"),
    run:
        # read fasta using bioconda obj
        fasta = SeqIO.parse(input.fasta, "fasta")

        # initialize kmerization object
        kmer = skm.vectorize.KmerVec(alphabet=config["alphabet"], k=config["k"])

        vecs, seqs, ids = list(), list(), list()
        for f in fasta:
            vecs.append(kmer.reduce_vectorize(f.seq))
            seqs.append(
                skm.vectorize.reduce(
                    f.seq,
                    alphabet=config["alphabet"],
                    mapping=skm.alphabet.FULL_ALPHABETS,
                )
            )
            ids.append(f.id)

        # save seqIO output and transformed vecs
        np.savez_compressed(output.data, ids=ids, seqs=seqs, vecs=vecs)

        with open(output.kmerobj, "wb") as f:
            pickle.dump(kmer, f)

