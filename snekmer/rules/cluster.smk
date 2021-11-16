# force snakemake v6.0+ (required for modules)
from snakemake.utils import min_version
min_version("6.0")

# load snakemake modules
module process_input:
    snakefile: "process_input.smk"
    config: config
module kmerize:
    snakefile: "kmerize.smk"
    config: config

# built-in imports
import gzip
import json
import pickle
from datetime import datetime
from glob import glob
from itertools import (product, repeat)
from multiprocessing import Pool
from os import makedirs
from os.path import (basename, dirname, exists, join, splitext)

# external libraries
import snekmer as skm
import numpy as np
import matplotlib.pyplot as plt
from pandas import (DataFrame, read_csv, read_json)
from Bio import SeqIO
from sklearn.linear_model import LogisticRegressionCV
from sklearn.model_selection import train_test_split, StratifiedKFold, cross_val_score
from sklearn.preprocessing import LabelEncoder
from sklearn.ensemble import RandomForestClassifier
from sklearn.tree import DecisionTreeClassifier


# change matplotlib backend to non-interactive
plt.switch_backend('Agg')

# collect all fasta-like files, unzipped filenames, and basenames
input_files = glob(join("input", "*"))
zipped = [fa for fa in input_files if fa.endswith('.gz')]
unzipped = [fa.rstrip('.gz') for fa, ext
            in product(input_files, config['input']['file_extensions'])
            if fa.rstrip('.gz').endswith(f".{ext}")]

# map extensions to basename (basename.ext.gz -> {basename: ext})
uz_map = {skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in zipped}
fa_map = {skm.utils.split_file_ext(f)[0]: skm.utils.split_file_ext(f)[1] for f in unzipped}
UZS = list(uz_map.keys())
FAS = list(fa_map.keys())
# NON_BGS, BGS = FAS, []

# parse any background files
bg_files = glob(join("input", "background", "*"))
if len(bg_files) > 0:
    bg_files = [skm.utils.split_file_ext(basename(f))[0] for f in bg_files]
NON_BGS, BGS = [f for f in FAS if f not in bg_files], bg_files

# terminate with error if invalid alphabet specified
skm.alphabet.check_valid(config['alphabet'])
# elif config['alphabet'] == 'custom':

# define output directory (helpful for multiple runs)
out_dir = skm.io.define_output_dir(config['alphabet'], config['k'],
                                   nested=config['output']['nested_dir'])

# define output files to be created by snekmer
rule all:
    input:
        expand(join("input", '{uz}'), uz=UZS),  # require unzipping
        # expand(join(out_dir, "processed", "{nb}.json"), nb=NON_BGS),
        # expand(join(out_dir, "features", "full", "{nb}.json.gz"), nb=NON_BGS),  # correctly build features
        expand(join(out_dir, "cluster", "{nb}.pkl"), nb=NON_BGS)  # require model-building


# if any files are gzip zipped, unzip them
use rule unzip from process_input with:
    output:
        join("input", '{uz}')
        # join("input", "{uz}.{uzext}") ?

# read and process parameters from config
use rule preprocess from process_input with:
    input:
        fasta=lambda wildcards: join("input", f"{wildcards.nb}.{fa_map[wildcards.nb]}")
    output:
        data=join(out_dir, "processed", "{nb}.json"),
        desc=join(out_dir, "processed", "{nb}_description.csv")
    log:
        join(out_dir, "processed", "log", "{nb}.log")

# generate kmer features space from user params
use rule generate from kmerize with:
    input:
        params=join(out_dir, "processed", "{nb}.json")
    output:
        labels=join(out_dir, "labels", "{nb}.txt")
    log:
        join(out_dir, "labels", "log", "{nb}.log")

# build kmer count vectors for each basis set
use rule vectorize_full from kmerize with:
    input:
        kmers=join(out_dir, "labels", "{nb}.txt"),
        params=join(out_dir, "processed", "{nb}.json"),
        fasta=lambda wildcards: join("input", f"{wildcards.nb}.{fa_map[wildcards.nb]}")
    log:
        join(out_dir, "features", "log", "{nb}.log")
    output:
        file=join(out_dir, "features", "full", "{nb}.json.gz")

# [in-progress] kmer walk
# if config['walk']:
    # use rule perform_kmer_walk from process_input with:
        # output:

# UNSUPERVISED WORKFLOW
rule score:
    input:
        kmers=join(out_dir, "labels", "{nb}.txt"),
        files=expand(join(out_dir, "features", "full", "{fa}.json.gz"),
                     fa=NON_BGS)
    output:
        df=join(out_dir, "features", "scores", "{nb}.csv.gz"),
        scores=join(out_dir, "score", "{nb}.csv")
    log:
        join(out_dir, "score", "log", "{nb}.log")
    run:
        # log script start time
        start_time = datetime.now()
        with open(log[0], 'a') as f:
            f.write(f"start time:\t{start_time}\n")

        # get kmers for this particular set of sequences
        kmers = skm.io.read_output_kmers(input.kmers)

        # parse all data and label background files
        label = config['score']['lname']
        data = skm.io.vecfiles_to_df(
            input.files, labels=config['score']['labels'], label_name=label
        )
        data['background'] = [skm.utils.split_file_ext(f)[0] in BGS for f in data['filename']]

        # log conversion step runtime
        skm.utils.log_runtime(log[0], start_time, step="vecfiles_to_df")

        # parse family names and only add if some are valid
        families = [
            skm.utils.split_file_ext(fn)[0] for fn in data['filename']
        ]
        if any(families):
            label = 'family'
            data[label] = families

        # define feature matrix of kmer vectors not from background set
        bg, non_bg = data[data['background']], data[~data['background']]
        full_feature_matrix = skm.score.to_feature_matrix(data['vector'].values)
        feature_matrix = skm.score.to_feature_matrix(non_bg['vector'].values)
        bg_feature_matrix = skm.score.to_feature_matrix(bg['vector'].values)
        # print(feature_matrix.T.shape, bg_feature_matrix.T.shape, np.array(kmers).shape)

        # compute class probabilities
        labels = non_bg[label].values
        class_probabilities = skm.score.feature_class_probabilities(
            feature_matrix.T, labels, kmers=kmers
        )

        # compute background sequence probabilities
        if len(bg) > 0:
            bg_labels = bg[label].values
            bg_probabilities = skm.score.feature_class_probabilities(
                bg_feature_matrix.T, bg_labels, kmers=kmers
            )

            # background family probability scores
            for fam in bg[label].unique():
                bg_scores = bg_probabilities[
                    bg_probabilities['label'] == fam
                ]['score'].values

                # normalize by max bg score
                # bg_norm = np.max(bg_scores)

                # get background scores for sequences
                bg_only_scores = skm.score.apply_feature_probabilities(
                    full_feature_matrix, bg_scores, scaler=config['score']['scaler'],
                    **config['score']['scaler_kwargs']
                )

                # normalize by max bg score attained by a sequence
                bg_norm = np.max(bg_only_scores)

                data[f"{fam}_background_score"] = bg_only_scores / bg_norm

        # assign family probability scores
        for fam in non_bg[label].unique():
            scores = class_probabilities[
                class_probabilities['label'] == fam
            ]['score'].values

            # normalize by sum of all positive scores
            # norm = np.sum([s for s in scores if s > 0])

            # include background sequences for score generation
            total_scores = skm.score.apply_feature_probabilities(
                full_feature_matrix, scores, scaler=config['score']['scaler'],
                **config['score']['scaler_kwargs']
            )

            # normalize by max score
            norm = np.max(total_scores)
            if norm < 1:  # prevent score explosion?
                norm = 1.0

            # assign percent score based on max positive score
            data[f"{fam}_score"] = total_scores / norm

            # weight family score by (1 - normalized bg score)
            if fam in bg[label].unique():
                data[f"{fam}_score_background_weighted"] = [
                    total * (1 - bg) for total, bg in zip(
                        data[f"{fam}_score"], data[f"{fam}_background_score"]
                    )
                ]

                # old scoring method
                data[f"{fam}_background_subtracted_score"] = [
                    total - bg for total, bg in zip(
                        data[f"{fam}_score"], data[f"{fam}_background_score"]
                    )
                ]

        # log time to compute class probabilities
        skm.utils.log_runtime(log[0], start_time, step="class_probabilities")

        # [IN PROGRESS] compute clusters
        clusters = skm.score.cluster_feature_matrix(full_feature_matrix)
        data['cluster'] = clusters

        # save all files to respective outputs
        delete_cols = ['vec', 'vector']
        for col in delete_cols:
            if col in data.columns:
                data = data.drop(columns=col)
            if col in class_probabilities.columns:
                class_probabilities = class_probabilities.drop(columns=col)
        data.to_csv(output.df, index=False, compression='gzip')
        class_probabilities.to_csv(output.scores, index=False)

        # record script endtime
        skm.utils.log_runtime(log[0], start_time)


rule cluster:
    input:
        files=rules.score.input.files,
        data=rules.score.output.df,
        scores=rules.score.output.scores
    output:
        cluster=join(out_dir, "cluster", "{nb}.pkl"),
        results=join(out_dir, "cluster", "results", "{nb}.csv"),
        figs=directory(join(out_dir, "cluster", "figures", "{nb}"))
    run:
        # data = skm.model.format_data_df(input.files)
        data = read_csv(input.data)
        scores = read_csv(input.scores)
        family = skm.utils.split_file_ext(input.scores)[0]  # skm.utils.get_family(input.scores, regex=config['input']['regex'])
        all_families = [skm.utils.split_file_ext(f)[0] for f in input.files]

        # prevent kmer NA being read as np.nan
        if config['k'] == 2:
            scores['kmer'] = scores['kmer'].fillna('NA')

        # get alphabet name
        if config['alphabet'] in skm.alphabet.ALPHABET_ORDER.keys():
            alphabet_name = skm.alphabet.ALPHABET_ORDER[config['alphabet']].capitalize()
        else:
            alphabet_name = str(config['alphabet']).capitalize()

        # AUC per family
        results = {'family': [], 'alphabet_name': [], 'k': [], 'scoring': [], 'score': [],  'cv_split': []}
        binary_labels = [True if value == family else False for value in data['family']]

        le = LabelEncoder()
        le.fit(binary_labels)

        # set random seed if specified
        random_state = np.random.randint(0, 2**32)
        if str(config['model']['random_state']) != "None":
            random_state = config['model']['random_state']

        X, y = data[f"{family}_score"].values.reshape(-1, 1), le.transform(binary_labels).ravel()
        cv = StratifiedKFold(config['model']['cv'])
        clf = LogisticRegressionCV(
            random_state=random_state, cv=cv, solver='liblinear', class_weight='balanced'
        )

        # ROC-AUC figure
        fig, ax = skm.plot.show_cv_roc_curve(
            clf, cv, X, y, title=f"{family} ROC Curve ({alphabet_name}, k = {config['k']})"
        )

        # collate ROC-AUC results
        results['family'] += [family] * config['model']['cv']
        results['alphabet_name'] += [alphabet_name.lower()] * config['model']['cv']
        results['k'] += [config['k']] * config['model']['cv']
        results['scoring'] += ['roc_auc'] * config['model']['cv']
        results['score'] += list(cross_val_score(clf, X, y, cv=cv, scoring='roc_auc'))
        results['cv_split'] += [i + 1 for i in range(config['model']['cv'])]

        # save ROC-AUC figure
        plt.tight_layout()
        if not exists(output.figs):
            makedirs(output.figs)
        fig.savefig(join(output.figs, f"{family}_roc-auc-curve_{alphabet_name.lower()}_k-{config['k']:02d}.png"))
        plt.close("all")

        # PR-AUC figure
        fig, ax = skm.plot.show_cv_pr_curve(
            clf, cv, X, y, title=f"{family} PR Curve ({alphabet_name}, k={config['k']})"
        )

        # collate PR-AUC results
        results['family'] += [family] * config['model']['cv']
        results['alphabet_name'] += [alphabet_name.lower()] * config['model']['cv']
        results['k'] += [config['k']] * config['model']['cv']
        results['scoring'] += ['pr_auc'] * config['model']['cv']
        results['score'] += list(cross_val_score(clf, X, y, cv=cv, scoring='average_precision'))
        results['cv_split'] += [i + 1 for i in range(config['model']['cv'])]

        # save PR-AUC figure
        plt.tight_layout()
        if not exists(output.figs):
            makedirs(output.figs)
        fig.savefig(join(output.figs, f"{family}_aupr-curve_{alphabet_name.lower()}_k-{config['k']:02d}.png"))
        plt.close("all")

        # save model
        clf.fit(X, y)
        with open(output.model, 'wb') as save_model:
            pickle.dump(clf, save_model)

        # save full results
        DataFrame(results).to_csv(output.results, index=False)

        # # define x, y matrices
        # X, y, Y = np.asarray([arr for arr in data['vec'].values]), data[family].values, data['family'].values
        # Xb = (X > 0) * 1  # binary presence/absence
        #
        # # restrict kmer vector by score
        # if config['model']['use_score']:
        #     scaler = skm.model.KmerScaler(n=config['model']['n'])
        #     score_list = scores[scores['label'] == family]['score'].values[0]
        #     scaler.fit(score_list)
        #     Xb = scaler.transform(Xb)
        #
        # Xb_train, Xb_test, y_train, y_test = train_test_split(
        #     Xb, y, test_size=0.25, stratify=y
        # )
        #
        # # train and save model
        # clf = skm.model.KmerModel(model=config['model']['type'], scaler=None)  # scaler currently separate from model
        # print(clf.model)
        # clf.fit(Xb_train, y_train)
        # print(clf.score(Xb_test, y_test))
        #
        # # save cv results and model
        # DataFrame(clf.search.cv_results_).to_csv(output.results, index=False)
        # with open(output.model, 'wb') as f:
        #     pickle.dump(clf, f, protocol=pickle.HIGHEST_PROTOCOL)
