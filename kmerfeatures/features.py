"""features: Output feature processing for the Kmer pipeline.

author: @christinehc
"""

# imports
from kmerfeatures.transform import vectorize_string


# functions
def output_features(format, output_file feature_sets=None,
                    labels=None, mode="w", **kwargs):
    """Generate output features based on input fasta file.

    Parameters
    ----------
    format : str
        File format; select one option from the following list:
            ('gist', 'sieve', 'matrix', 'both')
    output_file : str
        Name of output file (default: None).
    feature_sets : type
        Description of parameter `feature_sets`.
    labels : list
        Description of parameter `labels`.
    mode : str
        File write mode (default: 'w').
            For details, see documentation for Python built-in
            function open().

    Returns
    -------
    type
        Description of returned object.

    """
    # ensure valid format is specified
    if format not in ['gist', 'sieve', 'matrix', 'both']:
        raise ValueError(
            ('File format must be one of the following:'
             ' "gist", "sieve", "both", or "matrix".')
            )

    # update any gist files
    if format in ["gist", "both"]:
        read_gist_file(output_file, labels=labels,
                       feature_sets=feature_sets, mode=mode)

    # update any sieve files
    if format in ["sieve", "both"]:
        read_sieve_file(output_file, feature_sets=feature_sets, mode=mode,
                        **kwargs)

    # update matrix files
    if format == "matrix":
        read_matrix_file(output_file, labels=labels,
                         feature_sets=feature_sets, mode=mode)


def read_gist_file(filename, labels=None, feature_sets=None, mode='w'):
    """Read gist file and parse into output file.

    Parameters
    ----------
    filename : str
        Base filename (i.e. file name without .ext)
    labels : list
        (default: None)
    feature_sets : type
        Description of parameter `feature_sets`.
    mode : str
        (default: 'w')

    Returns
    -------
    type
        Description of returned object.

    """
    train_out = f"{filename}.train"
    class_out = f"%{filename}.class"

    # update train
    with open(train_out, mode) as trainf, open(class_out, mode) as classf:
        trainf.write("corner")
        classf.write("corner\tclass\n")

        if labels:
            for label in labels:
                trainf.write("\t%s" % label)
        else:
            for i in range(len(feature_sets[0]) - 1):
                trainf.write("\tlabel%d" % i)
        for features in feature_sets:
            output_gist_features(features=features, file=trainf)
            output_gist_class(features=features, file=classf)


def read_sieve_file(filename, feature_sets=None, mode='w', **kwargs):
    """Read sieve file and parse into output file.

    Parameters
    ----------
    filename : str
        Base filename (i.e. file name without .ext)
    labels : list
        (default: None)
    feature_sets : type
        Description of parameter `feature_sets`.
    mode : str
        (default: 'w')

    Returns
    -------
    type
        Description of returned object.

    """

    def output_sieve_features(features, filepath, example_index=None):
        """Write features to SIEVE output file.

        Parameters
        ----------
        features : type
            List of specified features.
        filepath : str
            File handle for naming of output files.
        example_index : dict
            Description of parameter `example_index` (default: None).

        Returns
        -------
        type
            Description of returned object.

        """
        # parse first item in feature list as feature ID
        fid = features[0]
        value = example_index.get(fid, 0.0)

        with open(filepath, "w+") as f:
            filepath.write("pattern\t%s\t%d\n" % (fid, len(features) - 1))
            filepath.write("\tinput\t%s" % fid)
            for f in features[1:]:
                filepath.write("\t%s" % f)
            filepath.write("\n")
            filepath.write("\toutput\t%s\t%d\n" % (fid, value))
            filepath.flush()

    pattern_out = f"{filename}.pattern"
    with open(pattern_out, mode) as f:
        for features in feature_sets:
            output_sieve_features(features=features, file=f)


def read_matrix_file(filename, labels=None, feature_sets=None, mode='w'):
    """Read matrix file and parse into output file.

    Parameters
    ----------
    filename : str
        Base filename (i.e. file name without .ext)
    labels : list
        (default: None)
    feature_sets : type
        Description of parameter `feature_sets`.
    mode : str
        (default: 'w')

    Returns
    -------
    type
        Description of returned object.

    """
    file_out = f"{filename}.txt"
    with open(file_out, mode) as f:
        if labels:
            f.write("%s" % labels[0])
            for label in labels[1:]:
                f.write("\t%s" % label)
            f.write("\n")
        if feature_sets:
            for features in feature_sets:
                output_gist_features(features=features, file=f)


def output_gist_features(filename, features):
    """Write features to gist output file.

    Parameters
    ----------
    filename : type
        Description of parameter `file`.
    features : type
        Description of parameter `features`.

    Returns
    -------
    type
        Description of returned object.

    """
    with open(filename, 'w') as f:)
        filename.write("%s" % features[0])
        for f in features[1:]:
            filename.write("\t%s" % f)
        filename.write("\n")
    # filename.flush()


def output_gist_class(filename, features, example_index=None):
    """Write gist class to specified output file.

    Parameters
    ----------
    filename : str
        File handle for naming of output files.
    features : list
        List of specified features.
    example_index : dict
        Description of parameter `example_index` (default: None).

    Returns
    -------
    type
        Description of returned object.

    """
    fid = features[0]
    value = example_index.get(fid, -1)
    file.write("%s\t%d\n" % (features[0], value))
    file.flush()


def define_feature_space(sequence_dict, kmer=None, map_function=None,
                         start=None, end=None, residues=None, min_rep_thresh=2,
                         verbose=False):
    """Short summary.

    Parameters
    ----------
    sequence_dict : type
        Description of parameter `sequence_dict`.
    kmer : type
        Description of parameter `kmer`.
    map_function : type
        Description of parameter `map_function`.
    start : type
        Description of parameter `start`.
    end : type
        Description of parameter `end`.
    residues : type
        Description of parameter `residues`.
    min_rep_thresh : type
        Description of parameter `min_rep_thresh`.
    verbose : bool
        If True, enables verbose output (default: False).

    Returns
    -------
    type
        Description of returned object.

    """
    # this routine will return

    feature_dict = {}

    for seq_id, seq in sequence_dict.items():
        feature_dict = vectorize_string(sequence=seq, kmer=kmer, map_function=map_function, feature_dict=feature_dict,
                                         start=start, end=end, residues=residues, return_dict=True)

    # if this is between 0 and 1 then it's a percentage
    if min_rep_thresh < 1 and min_rep_thresh > 0:
        min_rep_thresh = len(feature_dict.keys()) * min_rep_thresh

    # filter out all those below the min_rep_thresh
    if min_rep_thresh:
        filter_dict = {}
        for key in feature_dict.keys():
            if feature_dict[key] >= min_rep_thresh:
                filter_dict[key] = feature_dict[key]
    else:
        filter_dict = feature_dict

    if verbose:
        print(
            ("Feature space: {0} kmers with more than"
             "{1} representation in {2} sequences").format(
                 len(filter_dict),
                 config['input']['kmer']['min_rep_thresh'],
                 len(sequence_dict)
                 )
             )

    filter_list = filter_dict.keys()
    if len(filter_list) == 0:
        raise ValueError(
            ("Prefiltered feature space cannot be empty.")
            )

    return filter_dict
