# built-in imports
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

# print(NON_BGS, BGS)

# check alphabet validity
if (
    # raise error if alphabet not included in pre-defined set
    (
        # doesn't match integer designations
        (config['alphabet'] not in range(len(skm.alphabet.ALPHABETS)))
        # doesn't match str name designations
        and (config['alphabet'] not in skm.alphabet.ALPHABETS))
    # or doesn't match None (no mapping)
    and (str(config['alphabet']) != "None")
):  # and config['alphabet'] != 'custom':
    raise ValueError("Invalid alphabet specified; alphabet must be a"
                     " string (see snekmer.alphabet) or integer"
                     " n between"
                     f" {np.min(list(skm.alphabet.ALPHABET_ORDER.keys()))}"
                     " and"
                     f" {np.max(list(skm.alphabet.ALPHABET_ORDER.keys()))}"
                     ".")
# elif config['alphabet'] == 'custom':


# define output directory (helpful for multiple runs)
if config['output']['nested_dir']:
    alphabet_name = config['alphabet']
    if not isinstance(config['alphabet'], str):
        alphabet_name = skm.alphabet.ALPHABET_ORDER[alphabet_name]
    out_dir = join("output", alphabet_name, f"k-{config['k']:02}")
else:
    out_dir = "output"


# import subworkflow for unzipping any zipped input files
# subworkflow unzip:
#     # workdir:
#     #     join("tune")
#     snakefile:
#         join("rules", "unzip.smk")
#     configfile:
#         join("rules", "unzip_config.yaml")

# '{wildcards.token}.txt'.format(wildcards=wildcards) ?
# template for getting rule all files
def get_input(wildcards):
    input_list = []

    # unzipped files
    input_list.append(
        expand(join("input", '{uz}'),
               uz=UZS)
        )

    # different run modes
    if config['mode'] == 'supervised':
        input_list.append(
            expand(join(out_dir, "features", "{nb}", "{fa}.json"),
                   nb=NON_BGS, fa=FAS)
        )
        input_list.append(
            expand(join(out_dir, "model", "{nb}.pkl"),
                   nb=NON_BGS)
            )
    else:
        input_list.append(
            expand(join(out_dir, "features", "{nb}.json"),
                   nb=NON_BGS)
        )
    return input_list
#
rule all:
    input:
        get_input


# define main workflow
# rule all:
#     input:
#         expand(join("input", '{uz}'), uz=UZS),
#         expand(join(out_dir, "features", "{nb}", "{fa}.json"), nb=NON_BGS, fa=FAS),
#         # expand(join(out_dir), "score", "{nb}.csv", nb=NON_BGS),
#         expand(join(out_dir, "model", "{nb}.pkl"), nb=NON_BGS)
#         # expand(join(out_dir, "score", "{fa}.json"), fa=FAS)


# [in-progress] kmer walk
if config['walk']:
    rule perform_kmer_walk:
        input:
            fasta=get_fasta_files
        output:
            # need to fix code to properly generate an output...
        run:
            skm.walk.kmer_walk(input.fasta)


# if any files are gzip zipped, unzip them
if len(UZS) > 0:
    rule unzip:
        input:
            lambda wildcards: join("input", f"{wildcards.uz}.{uz_map[wildcards.uz]}.gz")
            # lambda wildcards: unzip(join("input", ))
        output:
            join("input", "{uz}.{uzext}")
        params:
            outdir=join("input", 'zipped')
        run:

    # shell:
    #     "mkdir {params.outdir} && cp {input} {params.outdir} && gunzip -c {input} > {output}"
            if wildcards.sample.endswith('.fastq'):
                shell("echo gzip {input}")
                shell("echo mv {input}.gz {params.outdir}")
            else:
                shell("mv {input} {params.outdir}")


# read and process parameters from config
rule preprocess:
    input:
        fasta=lambda wildcards: join("input", f"{wildcards.nb}.{fa_map[wildcards.nb]}"),
    output:
        data=join(out_dir, "processed", "{nb}.json"),
        desc=join(out_dir, "processed", "{nb}_description.csv")
    log:
        join(out_dir, "processed", "log", "{nb}.log")
    run:
        # log step initialization
        start_time = datetime.now()

        # read fasta file
        seq_list, id_list = skm.io.read_fasta(input.fasta)

        # if random alphabet specified, implement randomization
        if config['randomize_alphabet']:
            rand_alphabet = skm.transform.randomize_alphabet(config['input']['alphabet'])
            alphabet = [residues, map_name, rand_alphabet]
        else:
            alphabet = config['alphabet']
            if alphabet == "None":
                alphabet = None

        # define minimum threshold
        if config['mode'] == 'supervised':
            min_rep_thresh = config['min_rep_thresh']
        else:
            min_rep_thresh = 0

        # if no feature set is specified, define feature space
        if not config['input']['feature_set']:
            # prefilter fasta to cut down on the size of feature set
            filter_dict = skm.features.define_feature_space(
                {k: v for k, v in zip(id_list, seq_list)},
                config['k'],
                alphabet=alphabet,
                start=config['start'],
                end=config['end'],
                min_rep_thresh=min_rep_thresh,
                verbose=config['output']['verbose'],
                log_file=log[0],
                processes=config['processes']
            )
            filter_list = list(filter_dict.keys())
            assert len(filter_list) > 0, "Invalid feature space; terminating."
        else:
            # read in list of ids to use from file; NO FORMAT CHECK
            filter_list = []
            with open(config['input']['feature_set'], "r") as f:
                filter_list = skm.io.read_output_kmers(config['input']['feature_set'])

        # optional indexfile with IDs of good feature output examples
        if config['input']['example_index_file']:
            example_index = skm.io.read_example_index(
                config['input']['example_index_file']
            )
        else:
            example_index = {}

        # loop thru seqs, apply input params to preprocess seq list
        seen = []  # filter duplicates
        save_data = dict()

        # define recursive and nonrecursive saving patterns for params
        recursive = ['sequences', 'ids', 'residues']
        nonrecursive = ['alphabet', 'k', 'example_index', 'filter_list']
        all_dsets = recursive + nonrecursive

        for i in range(len(seq_list)):
            seq = seq_list[i]
            sid = id_list[i]

            # ignore duplicate ids
            if config['output']['filter_duplicates'] and sid in seen:
                continue
            seen.append(sid)

            seqs = [seq]
            sids = [sid]

            # shuffle the N-terminal sequence n times
            if config['output']['shuffle_n']:
                example_index[id] = 1.0
                scid_list, scramble_list, example_index = skm.transform.scramble_sequence(
                    sid, seq[:30], n=config['output']['shuffle_n'],
                    example_index=example_index
                )
                seqs += scramble_list
                sids += scid_list

                # include shuffled sequences in output
                if config['output']['shuffle_sequences']:
                    filename = join(out_dir, 'shuffled',
                                    wildcards.fa, "%s_shuffled.fasta" % sid)
                    if not exists(dirname(filename)):
                        makedirs(dirname(filename))
                    with open(filename, "w") as f:
                        for i in range(len(sids)):
                            f.write(">%s\n%s\n" % (sids[i], seqs[i]))

            # run SIEVE on the wt and each shuffled sequence
            if config['output']['n_terminal_file']:
                sids_n, seqs_n = skm.transform.make_n_terminal_fusions(
                    sid, config['output']['n_terminal_file']
                    )
                seqs += seqs_n
                sids += sids_n
            residues = None
            if config['nucleotide']:
                residues = "ACGT"

            # populate dictionary for json save file
            to_save = [seqs, sids, residues]
            save_label = recursive
            for dset, label in zip(to_save, save_label):
                if label in save_data.keys() and save_data[label] is not None:
                    save_data[label] = save_data[label] + dset
                else:
                    save_data[label] = dset

        # save variables not generated in loop
        for dset, label in zip(
            [alphabet, config['k'], example_index, filter_list],
            nonrecursive
        ):
            save_data[label] = dset

        # save all parameters into json
        with open(output.data, 'w') as f:
            json.dump(save_data, f)

        # read and save fasta descriptions into dataframe
        try:
            desc = skm.utils.parse_fasta_description(input.fasta)
            desc.to_csv(output.desc)
        except AttributeError:  # if no description exists > empty df
            DataFrame([]).to_csv(output.desc)

        # record script runtime
        end_time = datetime.now()
        with open(log[0], 'a') as f:
            f.write(f"start time:\t{start_time}\n")
            f.write(f"end time:\t{end_time}\n")
            f.write(f"total time:\t{skm.utils.format_timedelta(end_time - start_time)}")


rule generate:
    input:
        params=rules.preprocess.output.data
    output:
        labels=join(out_dir, "labels", "{nb}.txt")
    log:
        join(out_dir, "labels", "log", "{nb}.log")
    run:
        start_time = datetime.now()

        # read processed features
        with open(input.params, 'r') as f:
            params = json.load(f)

        # generate labels only
        labels = skm.transform.generate_labels(
            config['k'],
            alphabet=params['alphabet'],
            # residues=params['residues'],
            filter_list=params['filter_list']
        )
        if config['output']['format'] == "simple":
            skm.features.output_features(
                output.labels, "matrix", labels=labels
            )

        # record script runtime
        end_time = datetime.now()
        with open(log[0], 'a') as f:
            f.write(f"start time:\t{start_time}\n")
            f.write(f"end time:\t{end_time}\n")
            f.write(f"total time:\t{skm.utils.format_timedelta(end_time - start_time)}")


if config['mode'] == 'unsupervised':
    rule vectorize_full:
        input:
            kmers=rules.generate.output.labels,
            params=rules.preprocess.output.data,
            fastas=unzipped
        log:
            join(out_dir, "features", "log", "{nb}.log")
        output:
            join(out_dir, "features", "{nb}.json")
        run:
            # get kmers for this particular set of sequences
            kmers = skm.io.read_output_kmers(input.kmers)


elif config['mode'] == 'supervised':
    rule vectorize:
        input:
            kmers=rules.generate.output.labels,
            params=rules.preprocess.output.data,
            fastas=unzipped
        log:
            join(out_dir, "features", "log", "{nb}.log")
        output:
            files=expand(join(out_dir, "features", "{{nb}}", "{fa}.json"),
                         fa=FAS)
        run:
            start_time = datetime.now()

            # get kmers for this particular set of sequences
            kmers = skm.io.read_output_kmers(input.kmers)

            # read processed features
            with open(input.params, 'r') as f:
                params = json.load(f)

            # sort i/o lists to match wildcard order
            fastas = sorted(input.fastas)
            # print(fastas)
            outfiles = sorted(output.files)

            # revectorize based on full kmer list
            for i, fa in enumerate(fastas):
                results = {'seq_id': [], 'vector': []}
                seq_list, id_list = skm.io.read_fasta(fa)
                for seq, sid in zip(seq_list, id_list):
                    results['seq_id'] += [sid]
                    results['vector'] += [
                        skm.transform.vectorize_string(
                            seq, config['k'], params['alphabet'],
                            start=config['start'],
                            end=config['end'],
                            filter_list=kmers,  # params['filter_list'],
                            verbose=False,  # way too noisy for batch process
                            log_file=log[0]
                        )
                    ]

                with open(outfiles[i], 'w') as f:
                    json.dump(results, f)

            # record script runtime
            end_time = datetime.now()
            with open(log[0], 'a') as f:
                f.write(f"start time:\t{start_time}\n")
                f.write(f"end time:\t{end_time}\n")
                f.write(f"total time:\t{skm.utils.format_timedelta(end_time - start_time)}")


    rule score:
        input:
            kmers=rules.generate.output.labels,
            files=rules.vectorize.output.files
        output:
            df=join(out_dir, "features", "{nb}.csv"),
            scores=join(out_dir, "score", "{nb}.csv")
        log:
            join(out_dir, "score", "log", "{nb}.log")
        run:
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

            timepoint = datetime.now()
            with open(log[0], 'a') as f:
                f.write(f"vecfiles_to_df time:\t{skm.utils.format_timedelta(timepoint - start_time)}\n")

            # parse family names and only add if some are valid
            families = [
                skm.utils.get_family(fn, regex=config['input']['regex'])
                for fn in data['filename']
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
            )  #.drop(columns=['count'])

            # compute background sequence probabilities
            if len(bg) > 0:
                bg_labels = bg[label].values
                # print(labels)
                # print(bg_labels)
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

            new_timepoint = datetime.now()
            with open(log[0], 'a') as f:
                f.write(
                    "class_probabilities time:\t"
                    f"{skm.utils.format_timedelta(new_timepoint - timepoint)}\n"
                    )

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
            data.to_csv(output.df, index=False)
            class_probabilities.to_csv(output.scores, index=False)

            # record script runtime
            end_time = datetime.now()
            with open(log[0], 'a') as f:
                f.write(f"total time:\t{skm.utils.format_timedelta(end_time - start_time)}")


    rule model:
        input:
            files=rules.vectorize.output.files,
            data=rules.score.output.df,
            scores=rules.score.output.scores
        output:
            model=join(out_dir, "model", "{nb}.pkl"),
            results=join(out_dir, "model", "results", "{nb}.csv"),
            figs=directory(join(out_dir, "model", "figures", "{nb}"))
        run:
            # data = skm.model.format_data_df(input.files)
            data = read_csv(input.data)
            scores = read_csv(input.scores)
            family = skm.utils.get_family(input.scores, regex=config['input']['regex'])
            all_families = [skm.utils.get_family(f, regex=config['input']['regex']) for f in input.files]

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
                random_state=random_state, cv=cv, solver='liblinear', class_weight='balanceds'
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
