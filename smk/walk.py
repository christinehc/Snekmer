"""walk: Kmer walk module for Kmer pipeline.

author: @christinehc
"""

# functions
def kmer_walk(fastafile=None, maxk=20, seq_dump=False, **kw):
    # next read in sequences from the fasta file
    sequence_list = []
    sequence_dict = {}
    ids_list = []
    handle = open(fastafile, "r")
    for record in SeqIO.parse(handle, "fasta"):
        sequence_list.append(str(record.seq))
        ids_list.append(record.id)
        sequence_dict[record.id] = str(record.seq)
    handle.close()

    # need to make this a percentage - eliminate the bottom XX% of kmers by repreesentation
    minthresh = 10

    exclusion_list = None
    for kmer in range(1, maxk):
        # build a feature dict for this kmer and these sequences
        feature_dict = {}

        # short circuit the exclusion list (very slow) but allow it to count
        exclusion_list = []
        for i in range(len(sequence_list)):
            sequence = sequence_list[i]
            id = ids_list[i]

            feature_dict = string_vectorize(sequence=sequence, kmer=kmer, map_function="reduced_alphabet_0", feature_dict=feature_dict,
                                             exclusion_list=exclusion_list, return_dict=True)

        exclusion_list = []
        for key in feature_dict.keys():
            if feature_dict[key] < minthresh:
                exclusion_list.append(key)
        print("Kmer %d, number of remaining features %d total, number of remaining features occuring more than %d times %d, of %g possible, %g%%" %
              (kmer, len(feature_dict.keys()), minthresh, len(feature_dict.keys())-len(exclusion_list), 20**kmer, (len(feature_dict.keys())-len(exclusion_list))/20**kmer))

    if seq_dump:
        for seq in feature_dict.keys():
            if feature_dict[seq] > minthresh:
                print(seq)
