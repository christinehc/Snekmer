"""snekmer.smk: v1.0.0 code

author: @christinehc

"""
# snakemake config
from snakemake.utils import min_version

min_version("6.0")  # force snakemake v6.0+ (required for modules)

# imports
import pickle
from ast import literal_eval
from collections import defaultdict
from datetime import datetime
from glob import glob
from itertools import product
from os import makedirs
from os.path import basename, dirname, exists, join, splitext

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from Bio import SeqIO
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold
from sklearn.preprocessing import LabelEncoder

import snekmer as skm

# load modules
module process_input:
    snakefile:
        "process_input.smk"
    config:
        config


# change matplotlib backend to non-interactive
plt.switch_backend("Agg")

# collect all fasta-like files, unzipped filenames, and basenames
input_files = glob(join("input", "*"))
zipped = [fa for fa in input_files if fa.endswith(".gz")]
unzipped = [
    fa.rstrip(".gz")
    for fa, ext in product(input_files, config["input"]["file_extensions"])
    if fa.rstrip(".gz").endswith(f".{ext}")
]

# map extensions to basename (basename.ext.gz -> {basename: ext})
UZ_MAP = {
    skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in zipped
}
FA_MAP = {
    skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in unzipped
}

# get unzipped filenames
UZS = [f"{f}.{ext}" for f, ext in UZ_MAP.items()]

# isolate basenames for all files
FAS = list(FA_MAP.keys())

# parse any background files
bg_files = glob(join("input", "background", "*"))
if len(bg_files) > 0:
    bg_files = [skm.utils.split_file_ext(basename(f))[0] for f in bg_files]
NON_BGS, BGS = [f for f in FAS if f not in bg_files], bg_files

# terminate with error if invalid alphabet specified
skm.alphabet.check_valid(config["alphabet"])


# define output directory (helpful for multiple runs)
out_dir = skm.io.define_output_dir(
    config["alphabet"], config["k"], nested=config["output"]["nested_dir"]
)


# define output files to be created by snekmer
rule all:
    input:
        expand(join("input", "{uz}"), uz=UZS),  # require unzipping
        expand(join("output", "model", "{nb}.pkl"), nb=NON_BGS),  # require model-building


# if any files are gzip zipped, unzip them
use rule unzip from process_input with:
    output:
        join("input", "{uz}"),


# define rules
# read and process parameters from config
rule vectorize:
    input:
        fasta=lambda wildcards: join("input", f"{wildcards.nb}.{FA_MAP[wildcards.nb]}"),
    output:
        data=join("output", "vector", "{nb}.npz"),
        kmerobj=join("output", "kmerize", "{nb}.pkl"),
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


# def get_ids_vecs(wildcards):
#     """Retrieve ID file and vec file in matching order"""
#     ids = expand(join("output", "seq_id", "{fa}.npy"), fa=FILES)
#     basenames = [basename(f) for f in ids]
#     vecs = [join("output", "vector", f) for f in basenames]
#     return ids, vecs


rule score:
    input:
        kmerobj=join("output", "kmerize", "{nb}.pkl"),
        data=expand(join("output", "vector", "{fa}.npz"), fa=NON_BGS),
    output:
        data=join("output", "scoring", "sequences", "{nb}.csv.gz"),
        weights=join("output", "scoring", "weights", "{nb}.csv.gz"),
        scorer=join("output", "scoring", "{nb}.pkl"),
    log:
        join("output", "scoring", "log", "{nb}.log"),
    run:
        # log script start time
        start_time = datetime.now()
        label = (
            config["score"]["lname"]
            if str(config["score"]["lname"]) != "None"
            else "label"
        )  # e.g. "family"
        with open(log[0], "a") as f:
            f.write(f"start time:\t{start_time}\n")

        # get kmers for this particular set of sequences
        with open(input.kmerobj, "rb") as f:
            kmer = pickle.load(f)

        # tabulate vectorized seq data
        data = list()
        for f in input.data:
            loaded = np.load(f)
            data.append(
                pd.DataFrame(
                    {
                        "filename": splitext(basename(f))[0],
                        "sequence_id": list(loaded["ids"]),
                        "sequence": list(loaded["seqs"]),
                        "sequence_length": [len(s) for s in loaded["seqs"]],
                        "sequence_vector": list(loaded["vecs"]),
                    }
                )
            )

        data = pd.concat(data, ignore_index=True)
        data["background"] = [f in BGS for f in data["filename"]]

        # log conversion step runtime
        skm.utils.log_runtime(log[0], start_time, step="files_to_df")

        # parse family names and only add if some are valid
        families = [
            skm.utils.get_family(
                skm.utils.split_file_ext(fn)[0], regex=config["input"]["regex"]
            )
            for fn in data["filename"]
        ]
        if any(families):
            data[label] = families

        # binary T/F for classification into family
        family = skm.utils.get_family(wildcards.nb)
        binary_labels = [True if value == family else False for value in data[label]]

        # define k-fold split indices
        if config["model"]["cv"] > 1:
            cv = StratifiedKFold(n_splits=config["model"]["cv"], shuffle=True)

            # stratify splits by [0,1] family assignment
            for n, (i_train, _) in enumerate(
                cv.split(data["sequence_vector"], binary_labels)
            ):
                data[f"train_cv-{n + 1:02d}"] = [idx in i_train for idx in data.index]

        elif config["model"]["cv"] in [0, 1]:
            i_train, _ = train_test_split(data.index, stratify=binary_labels)
            data["train"] = [idx in i_train for idx in data.index]

        # generate family scores and object
        scorer = skm.model.KmerScorer()
        scorer.fit(
            list(kmer.kmer_set.kmers),
            data,
            skm.utils.get_family(wildcards.nb, regex=config["input"]["regex"]),
            label_col=label,
            vec_col="sequence_vector",
            **config["score"]["scaler_kwargs"],
        )

        # append scored sequences to dataframe
        data = data.merge(
            pd.DataFrame(scorer.scores["sample"]), left_index=True, right_index=True
        )
        if data.empty:
            raise ValueError("Blank df")

        # save score loadings
        class_probabilities = (
            pd.DataFrame(scorer.probabilities, index=scorer.kmers.basis)
            .reset_index()
            .rename(columns={"index": "kmer"})
        )

        # log time to compute class probabilities
        skm.utils.log_runtime(log[0], start_time, step="class_probabilities")

        # save all files to respective outputs
        delete_cols = ["vec", "sequence_vector"]
        for col in delete_cols:
            if col in class_probabilities.columns:
                class_probabilities = class_probabilities.drop(columns=col)
        data.drop(columns="sequence_vector").to_csv(
        output.data, index=False, compression="gzip"
        )
        class_probabilities.to_csv(output.weights, index=False, compression="gzip")
        with open(output.scorer, "wb") as f:
            pickle.dump(scorer, f)

        # record script endtime
        skm.utils.log_runtime(log[0], start_time)


rule model:
    input:
        # files=rules.score.input.files,
        raw=rules.score.input.data,
        data=rules.score.output.data,
        weights=rules.score.output.weights,
        kmerobj=rules.score.input.kmerobj,
    output:
        model=join("output", "model", "{nb}.pkl"),
        results=join("output", "model", "results", "{nb}.csv"),
        figs=directory(join("output", "model", "figures", "{nb}")),
    run:
        # create lookup table to match vector to sequence by file+ID
        lookup = {}
        for f in input.raw:
            loaded = np.load(f)
            lookup.update(
                {
                    (splitext(basename(f))[0], seq_id): seq_vec
                    for seq_id, seq_vec in zip(loaded["ids"], loaded["vecs"])
                }
            )

        # load all input data and encode rule-wide variables
        data = pd.read_csv(input.data)
        data["sequence_vector"] = [
            lookup[(seq_f, seq_id)]
            for seq_f, seq_id in zip(data["filename"], data["sequence_id"])
        ]
        scores = pd.read_csv(input.weights)
        family = skm.utils.get_family(
            skm.utils.split_file_ext(input.weights)[0], regex=config["input"]["regex"]
        )
        # get kmers for this particular set of sequences
        with open(input.kmerobj, "rb") as f:
            kmer = pickle.load(f)

        cv = config["model"]["cv"]

        # set category label name (e.g. "family")
        label = (
            config["score"]["lname"]
            if str(config["score"]["lname"]) != "None"
            else "label"
        )

        # prevent kmer NA being read as np.nan
        if config["k"] == 2:
            scores["kmer"] = scores["kmer"].fillna("NA")

        # get alphabet name
        if config["alphabet"] in skm.alphabet.ALPHABET_ORDER.keys():
            alphabet_name = skm.alphabet.ALPHABET_ORDER[config["alphabet"]].capitalize()
        else:
            alphabet_name = str(config["alphabet"]).capitalize()

        # generate [0, 1] labels for binary family assignment
        binary_labels = [True if value == family else False for value in data[label]]
        le = LabelEncoder()
        le.fit(binary_labels)

        # set and format input and label arrays; initialize model objs
        # need to make training or test set?
        X_all = data[f"{family}_score"].values.reshape(-1, 1)
        y_all = le.transform(binary_labels).ravel()

        # set random seed if specified
        rng = np.random.default_rng()
        random_state = (
            config["model"]["random_state"]
            if str(config["model"]["random_state"]) != "None"
            else rng.integers(low=0, high=32767)  # max for int16
        )

        # set and format input and label arrays; initialize model objs
        cols = [label, "alphabet_name", "k", "scoring"]
        results = {col: [] for col in cols + ["score", "cv_split"]}
        X, y = {i: {} for i in range(cv)}, {i: {} for i in range(cv)}
        for n in range(cv):

            # remove score cols that were generated from full dataset
            unscored_cols = [col for col in list(data.columns) if "_score" not in col]

            # filter data by training data per CV split
            i_train = data[data[f"train_cv-{n + 1:02d}"]].index
            i_test = data[~data[f"train_cv-{n + 1:02d}"]].index
            df_train = data.iloc[i_train][unscored_cols].reset_index(drop=True)
            df_test = data.iloc[i_test][unscored_cols].reset_index(drop=True)
            df_train_labels = [
                True if value == family else False for value in df_train[label]
            ]
            df_test_labels = [
                True if value == family else False for value in df_test[label]
            ]

            # score kmers separately per split
            scorer = skm.model.KmerScorer()
            scorer.fit(
                list(kmer.kmer_set.kmers),
                df_train,
                family,
                label_col=label,
                vec_col="sequence_vector",
                **config["score"]["scaler_kwargs"],
            )

            # append scored sequences to dataframe
            df_train = df_train.merge(
                pd.DataFrame(scorer.scores["sample"]), left_index=True, right_index=True
            )
            if df_train.empty:
                raise ValueError("Blank df")
            df_test = df_test.merge(
                pd.DataFrame(
                    scorer.predict(
                        skm.model.to_feature_matrix(df_test["sequence_vector"]),
                        list(kmer.kmer_set.kmers),
                    )
                ),
                left_index=True,
                right_index=True,
            ).rename(columns={0: f"{family}_score"})

            # save score loadings
            scores = (
                pd.DataFrame(scorer.probabilities, index=scorer.kmers.basis)
                .reset_index()
                .rename(columns={"index": "kmer"})
            )

            # save X,y array data for plot
            X[n]["train"] = df_train[f"{family}_score"].values.reshape(-1, 1)
            y[n]["train"] = le.transform(df_train_labels).ravel()

            X[n]["test"] = df_test[f"{family}_score"].values.reshape(-1, 1)
            y[n]["test"] = le.transform(df_test_labels).ravel()

        # ROC-AUC figure
        clf = LogisticRegression(
            random_state=random_state, solver="liblinear", class_weight="balanced"
        )
        fig, ax, auc_rocs = skm.plot.cv_roc_curve(
            clf, X, y, title=f"{family} ROC Curve ({alphabet_name}, k={config['k']})"
        )

        # collate ROC-AUC results
        results[label] += [family] * cv
        results["alphabet_name"] += [alphabet_name.lower()] * cv
        results["k"] += [config["k"]] * cv
        results["scoring"] += ["auc_roc"] * cv
        results["score"] += auc_rocs
        results["cv_split"] += [i + 1 for i in range(cv)]

        # save ROC-AUC figure
        plt.tight_layout()
        if not exists(output.figs):
            makedirs(output.figs)
        fig.savefig(
            join(
                output.figs,
                (
                    f"{family}_roc-auc-curve_{alphabet_name.lower()}"
                    f"_k-{config['k']:02d}.png"
                ),
            )
        )
        plt.close("all")

        # PR-AUC figure
        fig, ax, pr_aucs = skm.plot.cv_pr_curve(
            clf, X, y, title=f"{family} PR Curve ({alphabet_name}, k={config['k']})"
        )

        # collate PR-AUC results
        results[label] += [family] * cv
        results["alphabet_name"] += [alphabet_name.lower()] * cv
        results["k"] += [config["k"]] * cv
        results["scoring"] += ["pr_auc"] * cv
        results["score"] += pr_aucs
        results["cv_split"] += [i + 1 for i in range(cv)]

        # save PR-AUC figure
        plt.tight_layout()
        fig.savefig(
            join(
                output.figs,
                (
                    f"{family}_aupr-curve_{alphabet_name.lower()}"
                    f"_k-{config['k']:02d}.png"
                ),
            )
        )
        plt.close("all")

        # save model
        clf.fit(X_all, y_all)
        with open(output.model, "wb") as save_model:
            pickle.dump(clf, save_model)

        # save full results
        pd.DataFrame(results).to_csv(output.results, index=False)
