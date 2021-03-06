import collections
import re
import csv
import gzip
import sys
import itertools

from . import utils

try:
    import pysam
except ImportError:
    pysam = None

# Metadata parsers/constants
RESERVED_INFO = {
    'AA': 'String', 'AC': 'Integer', 'AF': 'Float', 'AN': 'Integer',
    'BQ': 'Float', 'CIGAR': 'String', 'DB': 'Flag', 'DP': 'Integer',
    'END': 'Integer', 'H2': 'Flag', 'MQ': 'Float', 'MQ0': 'Integer',
    'NS': 'Integer', 'SB': 'String', 'SOMATIC': 'Flag', 'VALIDATED': 'Flag'
}

RESERVED_FORMAT = {
    'GT': 'String', 'DP': 'Integer', 'FT': 'String', 'GL': 'Float',
    'GQ': 'Float', 'HQ': 'Float'
}

Info = collections.namedtuple('Info', ['id', 'num', 'type', 'desc'])
Filter = collections.namedtuple('Filter', ['id', 'desc'])
Format = collections.namedtuple('Format', ['id', 'num', 'type', 'desc'])
Contig = collections.namedtuple('Contig', ['id', 'length'])

HOM_REF = 0
HET = 1
HOM_ALT = 3
UNKNOWN = 2

cdef _Call _parse_sample(char *sample, list samp_fmt,
                               list samp_fmt_types, list samp_fmt_nums,
                               char *name, Record rec):

    cdef dict sampdict = {x: None for x in samp_fmt}
    cdef list lvals

    cdef list svals = sample.split(":")

    cdef int i
    cdef int N = len(svals)
    for i in range(N):
        fmt = samp_fmt[i]
        entry_type = samp_fmt_types[i]
        entry_num = samp_fmt_nums[i]
        vals = svals[i]

        # short circuit the most common
        if vals == ".":
            continue
        if vals == "./.":
            continue
        if vals == "":
            continue


        # we don't need to split single entries
        if entry_num == 1 or (entry_num is None and ',' not in vals):
            if entry_type == 'Integer':
                if vals.isdigit():
                    sampdict[fmt] = int(vals)
                    continue
                try:
                    sampdict[fmt] = float(vals)
                except ValueError:
                    sampdict[fmt] = vals
                continue
            elif entry_type == 'Float':
                sampdict[fmt] = float(vals)
            else:
                sampdict[fmt] = vals

            continue

        if entry_num == 1 and entry_type == 'String':
            sampdict[fmt] = vals
            continue

        lvals = vals.split(',')

        if entry_type == 'Integer':
            sampdict[fmt] = [int(x) if x != '.' else '.' for x in lvals]
        elif entry_type in ('Float', 'Numeric'):
            sampdict[fmt] = [float(x) if x != '.' else '.' for x in lvals]
        else:
            sampdict[fmt] = vals
    return _Call(rec, name, sampdict)

cdef inline list _map(func, list iterable, char *bad='.'):
    '''``map``, but make bad values None.'''
    return [func(x) if x != bad else None for x in iterable]

class _vcf_metadata_parser(object):
    '''Parse the metadat in the header of a VCF file.'''
    def __init__(self):
        super(_vcf_metadata_parser, self).__init__()
        self.info_pattern = re.compile(r'''\#\#INFO=<
            ID=(?P<id>[^,]+),\s*
            Number=(?P<number>-?\d+|\.|[AGR]),\s*
            Type=(?P<type>Integer|Float|Flag|Character|String),\s*
            Description="(?P<desc>[^"]*)"
            (?:,\s*Source="(?P<source>[^"]*)")?
            (?:,\s*Version="?(?P<version>[^"]*)"?)?
            >''', re.VERBOSE)
        self.filter_pattern = re.compile(r'''\#\#FILTER=<
            ID=(?P<id>[^,]+),\s*
            Description="(?P<desc>[^"]*)"
            >''', re.VERBOSE)
        self.alt_pattern = re.compile(r'''\#\#ALT=<
            ID=(?P<id>[^,]+),\s*
            Description="(?P<desc>[^"]*)"
            >''', re.VERBOSE)
        self.format_pattern = re.compile(r'''\#\#FORMAT=<
            ID=(?P<id>.+),\s*
            Number=(?P<number>-?\d+|\.|[AGR]),\s*
            Type=(?P<type>.+),\s*
            Description="(?P<desc>.*)"
            >''', re.VERBOSE)
        #this will throw away assembly and any other crap
        self.contig_pattern = re.compile(r'''\#\#contig=<
            ID=(?P<id>[^>,]+)
            (,.*length=(?P<length>-?\d+))?
            .*
            >''', re.VERBOSE)
        self.meta_pattern = re.compile(r'''##(?P<key>.+?)=(?P<val>.+)''')

    def read_info(self, info_string):
        '''Read a meta-information INFO line.'''
        match = self.info_pattern.match(info_string)
        if not match:
            raise SyntaxError(
                "One of the INFO lines is malformed: %s" % info_string)

        try:
            num = int(match.group('number'))
            if num < 0:
                num = None
        except ValueError:
            num = None

        info = Info(match.group('id'), num,
                     match.group('type'), match.group('desc'))

        return (match.group('id'), info)

    def read_filter(self, filter_string):
        '''Read a meta-information FILTER line.'''
        match = self.filter_pattern.match(filter_string)
        if not match:
            raise SyntaxError(
                "One of the FILTER lines is malformed: %s" % filter_string)

        filt = Filter(match.group('id'), match.group('desc'))

        return (match.group('id'), filt)

    def read_format(self, format_string):
        '''Read a meta-information FORMAT line.'''
        match = self.format_pattern.match(format_string)
        if not match:
            raise SyntaxError(
                "One of the FORMAT lines is malformed: %s" % format_string)

        try:
            num = int(match.group('number'))
            if num < 0:
                num = None
        except ValueError:
            num = None

        form = Format(match.group('id'), num,
                       match.group('type'), match.group('desc'))

        return (match.group('id'), form)

    def read_contig(self, contig_string):
        match = self.contig_pattern.match(contig_string)
        if not match:
            raise SyntaxError("One of the contig lines is malformed: {}".format(contig_string))

        contig = Contig(match.group('id'), match.group('length'))

        return (match.group('id'), contig)

    def read_meta(self, meta_string):
        match = self.meta_pattern.match(meta_string)
        return match.group('key'), match.group('val')


cdef class _Call(object):
    """ A genotype call, a cell entry in a VCF file"""

    cdef public bytes sample   #NA12878
    cdef bytes gt_nums  #'0/1'
    # use bytes instead of char * because of C -> Python string complications
    # see: http://docs.cython.org/src/tutorial/strings.html
    cdef public Record site   #instance of Record
    cdef public dict data
    cdef public bint called, phased
    cdef list alleles

    def __cinit__(self, Record site, char *sample, dict data):
        #: The ``Record`` for this ``_Call``
        self.site = site
        #: The sample name
        self.sample = sample
        #: Dictionary of data from the VCF file
        self.data = data
        # '0/1', '0/0', etc.
        self.gt_nums = self.data.get('GT', None)
        # True if the GT is not ./.
        self.called = self.gt_nums is not None
        # True if the GT is phased (A|G, not A/G)
        self.phased = self.called and '|' in self.data['GT']

        if self.called:
            self.alleles = self.gt_nums.split('|' if self.phased else '/')
        else:
            self.alleles = []

    def __repr__(self):
        return "Call(sample=%s, GT=%s, GQ=%s)" % (self.sample, self.gt_nums, self.data.get('GQ', ''))

    def __richcmp__(self, other, int op):
        """ Two _Calls are equal if their Records are equal
            and the samples and ``gt_type``s are the same
        """
        # < 0 | <= 1 | == 2 | != 3 |  > 4 | >= 5
        if op == 2: # 2
            return (self.site == other.site
                    and self.sample == other.sample
                    and self.gt_type == other.gt_type)

    def __getitem__(self, key):
        """ Lookup value, backwards compatibility """
        return self.data[key]

    property gt_bases:
        def __get__(self):
            '''The actual genotype alleles.
               E.g. if VCF genotype is 0/1, return A/G
            '''
            # nothing to do if no genotype call
            if self.called:
                # grab the numeric alleles of the gt string; tokenize by phasing
                # lookup and return the actual DNA alleles
                phase_char = ['/', '|'][self.phased]
                try:
                    return phase_char.join([self.site.alleles[int(a)] \
                                           if a != '.' else '.' for a in
                                           self.alleles])
                except KeyError:
                    sys.stderr.write("Allele number not found in list of alleles\n")
            else:
                return None

    property gt_type:

        def __get__(self):
            '''The type of genotype.
               0 / 00000000 hom ref
               1 / 00000001 het
               2 / 00000010 missing
               3 / 00000011 hom alt
               hom_ref  = 0
               het      = 1
               hom_alt  = 3  (we don;t track _which+ ALT)
               uncalled = 2
            '''
            # extract the numeric alleles of the gt string
            gt_type = None
            if self.called:
                # grab the numeric alleles of the gt string; tokenize by phasing

                if len(self.alleles) == 2:
                    if self.alleles[0] == self.alleles[1]:
                        if self.alleles[0] == "0":
                            gt_type = HOM_REF
                        else:
                            gt_type = HOM_ALT
                    else:
                        gt_type = HET
                elif len(self.alleles) == 1:
                    if self.alleles[0] == "0":
                        gt_type = HOM_REF
                    else:
                        gt_type = HOM_ALT

            return gt_type

    property gt_depth:
        def __get__(self):
            '''The depth of aligned sequences that led to the genotype
            call for this sample.
            '''
            # extract the numeric alleles of the gt string
            try:
                depth = self.data['DP']
                if depth is not None:
                    return depth
                else:
                    return -1
            except KeyError:
                return -1

    property gt_ref_depth:
        def __get__(self):
            '''The depth of aligned sequences that supported the
            reference allele for this sample.
            '''
            # extract the numeric alleles of the gt string
            if 'AD' in self.data:
                depths = self.data['AD']
                if depths is not None:
                    # require bi-allelic
                    if isinstance(depths, (list, tuple)) and len(depths) == 2:
                        d = depths[0]
                        if d is None:
                            return -1
                        return d
                    else:
                        # ref allele is first
                        return -1
                else:
                    return -1
            elif 'RO' in self.data:
                if self.data['RO'] is not None:
                    return self.data['RO']
                else:
                    return -1
            else:
                return -1

    property gt_phred_likelihoods:
        def __get__(self):
            if 'PL' in self.data:
                return self.data['PL']
                # phred-scaled.
            elif 'GL' in self.data and self.data['GL'] is not None:
                # it's not usable anyway, so return None
                if not isinstance(self.data["GL"], list):
                    return None
                return [int(round(-10 * g)) if g is not None and g != '.' else None for g in self.data['GL']]
            else:
                return []


    property gt_alt_depth:
        def __get__(self):
            '''The depth of aligned sequences that supported the
            alternate allele for this sample.
            '''
            # extract the numeric alleles of the gt string

            # GATK style
            if 'AD' in self.data:
                depths = self.data['AD']
                if depths is not None:
                    # require bi-allelic
                    if not isinstance(depths, (list, tuple)) or len(depths) != 2:
                        return -1
                    else:
                        # alt allele is second
                        d = depths[1]
                        if d is None:
                            return -1
                        return d
                else:
                    return -1
            # Freebayes style
            elif 'AO' in self.data:
                depth = self.data['AO']
                if depth is not None:
                    # require bi-allelic
                    if isinstance(depth, list):
                        return -1
                    else:
                        return depth
                else:
                    return -1
            else:
                return -1

    @property
    def gt_qual(self):
        '''The PHRED-scaled quality of genotype
        call for this sample.
        '''
        # extract the numeric alleles of the gt string
        try:
            qual = self.data['GQ']
            if qual is not None:
                return qual
            else:
                return -1
        except KeyError:
            return -1

    property gt_copy_number:
        def __get__(self):
            '''The copy number prediction for this sample.
            '''
            # extract the numeric alleles of the gt string
            if not 'CN' in self.data:
                return -1
            qual = self.data['CN']
            if qual is not None:
                return qual
            else:
                return -1

    @property
    def is_variant(self):
        """ Return True if not a reference call """
        if not self.called:
            return None
        return self.gt_type != HOM_REF

    @property
    def is_het(self):
        """ Return True for heterozygous calls """
        if not self.called:
            return None
        return self.gt_type == HET


cdef class Record(object):
    """ A set of calls at a site.  Equivalent to a line in a VCF file.

        The standard VCF fields:
        CHROM, POS, ID,
        REF, ALT, QUAL,
        FILTER, INFO, & FORMAT are available as properties.

        The list of genotype calls is in the ``samples`` property.
    """

    # initialize Cython variables for all of the base attrs.
    cdef public list alleles, samples, ALT, gt_bases, gt_types, gt_phases, \
              gt_depths, gt_ref_depths, gt_alt_depths, gt_quals, gt_copy_numbers,\
              gt_phred_likelihoods
    # use bytes instead of char * because of C -> Python string complications
    # see: http://docs.cython.org/src/tutorial/strings.html
    cdef readonly bytes CHROM, ID, FORMAT
    cdef public REF
    cdef readonly object FILTER, QUAL
    cdef public int POS, start, end, num_hom_ref, num_het, num_hom_alt, \
             num_unknown, num_called
    cdef public dict INFO
    cdef public dict _sample_indexes
    cdef public bint has_genotypes

    def __cinit__(self, char *CHROM, int POS, char *ID,
                        char *REF, list ALT, object QUAL=None,
                        object FILTER=None, dict INFO=None, object FORMAT=None,
                        dict sample_indexes=None, list samples=None,
                        list gt_bases=None, list gt_types=None,
                        list gt_phases=None, list gt_depths=None,
                        list gt_ref_depths=None, list gt_alt_depths=None,
                        list gt_quals=None, list gt_copy_numbers=None, list gt_phred_likelihoods=None,
                        int num_hom_ref=0, int num_het=0, int num_hom_alt=0, int num_unknown=0, int num_called=0):
        # CORE VCF fields
        self.CHROM = CHROM
        self.POS = POS
        self.ID = ID
        self.REF = REF
        self.ALT = ALT
        self.QUAL = QUAL
        self.FILTER = FILTER
        self.INFO = INFO
        self.FORMAT = FORMAT
        # DERIVED fields
        self.start = self.POS - 1
        self.end = self.start + len(self.REF)
        if 'END' in self.INFO:
             self.end = self.INFO['END']
        else:
             self.end = self.start + len(self.REF)
        self.alleles = [self.REF]
        self.alleles.extend(self.ALT)
        self.samples = samples
        self._sample_indexes = sample_indexes
        self.gt_bases = gt_bases
        self.gt_types = gt_types
        self.gt_phases = gt_phases
        self.gt_depths = gt_depths
        self.gt_ref_depths = gt_ref_depths
        self.gt_alt_depths = gt_alt_depths
        self.gt_quals = gt_quals
        self.gt_copy_numbers = gt_copy_numbers
        self.gt_phred_likelihoods = gt_phred_likelihoods
        self.num_hom_ref = num_hom_ref
        self.num_het = num_het
        self.num_hom_alt = num_hom_alt
        self.num_unknown = num_unknown
        self.num_called = num_called
        if self.FORMAT is not None and sample_indexes is not None:
            self.has_genotypes = True
        else:
            self.has_genotypes = False

    def __richcmp__(self, other, int op):
        """ Records are equal if they describe the same variant (same position, alleles) """

        # < 0 | <= 1 | == 2 | != 3 |  > 4 | >= 5
        if op == 2: # 2
            return (self.CHROM == other.CHROM and
                    self.POS == other.POS and
                    self.REF == other.REF and
                    self.ALT == other.ALT)

    def __iter__(self):
        return iter(self.samples)

    def _format_alt(self):
        return ','.join([x or '.' for x in self.ALT])

    def _format_qual(self):
        return str(self.QUAL) if self.QUAL is not None else None

    def _format_filter(self):
        if self.FILTER is None:
            return None

        if isinstance(self.FILTER, basestring):
            return self.FILTER

        #filter is not empty or a string so we assume it's a list
        return ';'.join(self.FILTER)

    def _format_info(self):
        if not self.INFO:
            return '.'
        return ';'.join(["%s=%s" % (x, self._stringify(y)) for x, y in self.INFO.items()])

    def _format_sample(self, sample):
        if sample.data.get("GT", None) is None and not self.is_sv:
            return "./."
        return ':'.join(self._stringify(sample.data[f]) for f in self.FORMAT.split(':'))

    def _stringify(self, x, none='.'):
        if type(x) == type([]):
            return ','.join(self._map(str, x, none))
        return str(x) if x is not None else none

    def _map(self, func, iterable, none='.'):
        '''``map``, but make None values none.'''
        return [func(x) if x is not None else none
                for x in iterable]

    def __repr__(self):
        if self.has_genotypes == True:
            core = "\t".join([self.CHROM, str(self.POS), str(self.ID), str(self.REF), self._format_alt(),
                          self._format_qual() or '.', self._format_filter() or 'PASS', self._format_info(), self.FORMAT])
            samples = "\t".join([self._format_sample(sample) for sample in self.samples])
            return core + "\t" + samples
        else:
            return "\t".join([self.CHROM, str(self.POS), str(self.ID), str(self.REF), self._format_alt(),
                          self._format_qual() or '.', self._format_filter() or '.', self._format_info()])


    def __cmp__(self, other):
        return cmp( (self.CHROM, self.POS), (other.CHROM, other.POS))

    def add_format(self, fmt):
        tmp = self.FORMAT + ':' + fmt
        self.FORMAT = tmp

    def add_filter(self, flt):
        if self.FILTER is None or self.FILTER == b'PASS':
            self.FILTER = b''
        else:
            tmp = self.FILTER + ';'
            self.FILTER = tmp
        tmp = self.FILTER + flt
        self.FILTER = tmp

    def add_info(self, info, value=True):
        self.INFO[info] = value

    def genotype(self, name):
        """ Lookup a ``_Call`` for the sample given in ``name`` """
        return self.samples[self._sample_indexes[name]]

    @property
    def call_rate(self):
        """ The fraction of genotypes that were actually called. """
        return float(self.num_called) / float(len(self.samples))

    @property
    def aaf(self):
        """ The allele frequency of the alternate allele.
           NOTE 1: Punt if more than one alternate allele.
           NOTE 2: Denominator calc'ed from _called_ genotypes.
        """
        # skip if more than one alternate allele. assumes bi-allelic
        if len(self.ALT) > 1:
            return None
        hom_ref = self.num_hom_ref
        het = self.num_het
        hom_alt = self.num_hom_alt
        num_chroms = float(2.0*self.num_called)
        if num_chroms == 0.0:
            return 0.0
        else:
            return float(het + 2*hom_alt)/float(num_chroms)

    @property
    def nucl_diversity(self):
        """
        pi_hat (estimation of nucleotide diversity) for the site.
        This metric can be summed across multiple sites to compute regional
        nucleotide diversity estimates.  For example, pi_hat for all variants
        in a given gene.

        Derived from:
        \"Population Genetics: A Concise Guide, 2nd ed., p.45\"
          John Gillespie.
        """
        # skip if more than one alternate allele. assumes bi-allelic
        if len(self.ALT) > 1:
            return None
        p = self.aaf
        q = 1.0-p
        num_chroms = float(2.0*self.num_called)
        return float(num_chroms/(num_chroms-1.0)) * (2.0 * p * q)

    def get_hom_refs(self):
        """ The list of hom ref genotypes"""
        return [s for s in self.samples if s.gt_type == 0]

    def get_hom_alts(self):
        """ The list of hom alt genotypes"""
        return [s for s in self.samples if s.gt_type == 3]

    def get_hets(self):
        """ The list of het genotypes"""
        return [s for s in self.samples if s.gt_type == 1]

    def get_unknowns(self):
        """ The list of unknown genotypes"""
        return [s for s in self.samples if s.gt_type is None]

    @property
    def is_snp(self):
        """ Return whether or not the variant is a SNP """
        if len(self.REF) > 1: return False
        for alt in self.ALT:
            if alt not in ['A', 'C', 'G', 'T']:
                return False
        return True

    @property
    def is_indel(self):
        """ Return whether or not the variant is an INDEL """
        is_sv = self.is_sv

        if len(self.REF) > 1 and not is_sv: return True
        for alt in self.ALT:
            if alt is None or alt == '-':
                return True
            elif len(alt) != len(self.REF):
                # the diff. b/w INDELs and SVs can be murky.
                if not is_sv:
                    # 1	2827693	.	CCCCTCGCA	C	.	PASS	AC=10;
                    return True
                else:
                    # 1	2827693	.	CCCCTCGCA	C	.	PASS	SVTYPE=DEL;
                    return False
        return False

    @property
    def is_sv(self):
        """ Return whether or not the variant is a structural variant """
        if self.INFO.get('SVTYPE') is None:
            return False
        return True

    @property
    def is_transition(self):
        """ Return whether or not the SNP is a transition """
        # if multiple alts, it is unclear if we have a transition
        if len(self.ALT) > 1: return False

        if self.is_snp:
            # just one alt allele
            alt_allele = self.ALT[0]
            if ((self.REF == b'A' and alt_allele == b'G') or
                (self.REF == b'G' and alt_allele == b'A') or
                (self.REF == b'C' and alt_allele == b'T') or
                (self.REF == b'T' and alt_allele == b'C')):
                return True
            else: return False
        else: return False

    @property
    def is_deletion(self):
        """ Return whether or not the INDEL is a deletion """
        # if multiple alts, it is unclear if we have a transition
        if len(self.ALT) > 1: return False

        if self.is_indel:
            # just one alt allele
            alt_allele = self.ALT[0]
            if alt_allele is None:
                return True
            if len(self.REF) > len(alt_allele):
                return True
            else: return False
        else: return False

    @property
    def var_type(self):
        """
        Return the type of variant [snp, indel, unknown]
        TO DO: support SVs
        """
        if self.is_snp:
            return "snp"
        elif self.is_indel:
            return "indel"
        elif self.is_sv:
            return "sv"
        else:
            return "unknown"

    @property
    def var_subtype(self):
        """
        Return the subtype of variant.
        - For SNPs and INDELs, yeild one of: [ts, tv, ins, del]
        - For SVs yield either "complex" or the SV type defined
          in the ALT fields (removing the brackets).
          E.g.:
               <DEL>       -> DEL
               <INS:ME:L1> -> INS:ME:L1
               <DUP>       -> DUP

        The logic is meant to follow the rules outlined in the following
        paragraph at:

        http://www.1000genomes.org/wiki/Analysis/Variant%20Call%20Format/vcf-variant-call-format-version-41

        "For precisely known variants, the REF and ALT fields should contain
        the full sequences for the alleles, following the usual VCF conventions.
        For imprecise variants, the REF field may contain a single base and the
        ALT fields should contain symbolic alleles (e.g. <ID>), described in more
        detail below. Imprecise variants should also be marked by the presence
        of an IMPRECISE flag in the INFO field."
        """
        if self.is_snp:
            if self.is_transition:
                return "ts"
            elif len(self.ALT) == 1:
                return "tv"
            else: # multiple ALT alleles.  unclear
                return "unknown"
        elif self.is_indel:
            if self.is_deletion:
                return "del"
            elif len(self.ALT) == 1:
                return "ins"
            else: # multiple ALT alleles.  unclear
                return "unknown"
        elif self.is_sv:
            if self.INFO['SVTYPE'] == "BND":
                return "complex"
            elif self.is_sv_precise:
                return self.INFO['SVTYPE']
            else:
                # first remove both "<" and ">" from ALT
                return self.ALT[0].strip('<>')
        else:
            return "unknown"

    @property
    def sv_end(self):
        """ Return the end position for the SV """
        if self.is_sv:
            return self.INFO['END']
        return None

    @property
    def is_sv_precise(self):
        """ Return whether the SV cordinates are mapped
            to 1 b.p. resolution.
        """
        if self.INFO.get('IMPRECISE') is None and not self.is_sv:
            return False
        elif self.INFO.get('IMPRECISE') is not None and self.is_sv:
            return False
        elif self.INFO.get('IMPRECISE') is None and self.is_sv:
            return True

    @property
    def is_monomorphic(self):
        """ Return True for reference calls """
        return len(self.ALT) == 1 and self.ALT[0] is None

cdef class Reader(object):

    """ Reader for a VCF v 4.1 file, an iterator returning ``Record objects`` """
    cdef bytes _col_defn_line
    cdef char _prepend_chr
    cdef public object reader
    cdef bint compressed, prepend_chr
    cdef public object metadata, infos, filters, formats, contigs,
    cdef readonly dict _sample_indexes
    cdef list _header_lines, samp_data
    cdef public list samples
    cdef object _tabix
    cdef public object filename
    cdef int num_samples

    def __init__(self, fsock=None, filename=None,
                        bint compressed=False, bint prepend_chr=False):
        """ Create a new Reader for a VCF file.

            You must specify a filename.  Gzipped streams
            or files are attempted to be recogized by the file extension, or gzipped
            can be forced with ``compressed=True``
        """
        super(VCFReader, self).__init__()

        if not (fsock or filename):
            raise Exception('You must provide at least fsock or filename')

        if filename:
            self.filename = filename
            if fsock is None:
                self.reader = file(filename)

        if fsock:
            self.reader = fsock
            if filename is None:
                if hasattr(fsock, 'name'):
                    filename = fsock.name
            self.filename = filename

        if compressed or (filename and filename.endswith('.gz')):
            self.reader = gzip.GzipFile(fileobj=self.reader)

        #: metadata fields from header
        self.metadata = collections.OrderedDict()
        #: INFO fields from header
        self.infos = collections.OrderedDict()
        #: FILTER fields from header
        self.filters = collections.OrderedDict()
        #: FORMAT fields from header
        self.formats = collections.OrderedDict()
        self.contigs = collections.OrderedDict()
        self.samples = []
        self._sample_indexes = {}
        self._header_lines = []
        self._col_defn_line = None
        self._tabix = None
        self._prepend_chr = prepend_chr
        self._parse_metainfo()

    def __iter__(self):
        return self

    def seek(self, offset):
        self.reader.seek(offset)

    def tell(self):
        return self.reader.tell()

    property raw_header:
        """Dump the raw, unparsed header lines"""
        def __get__(self):
            return ''.join(self._header_lines)

    def _parse_metainfo(self):
        '''Parse the information stored in the metainfo of the VCF.

        The end user shouldn't have to use this.  She can access the metainfo
        directly with ``self.metadata``.
        '''
        # NOTE: Not sure why this was necessary in PyVCF
        # for attr in ('metadata', 'infos', 'filters', 'formats'):
        #     setattr(self, attr, {})

        parser = _vcf_metadata_parser()

        line = self.reader.next()
        while line.startswith('##'):
            self._header_lines.append(line)
            line = line.rstrip('\n')

            if line.startswith('##INFO'):
                key, val = parser.read_info(line)
                self.infos[key] = val

            elif line.startswith('##FILTER'):
                key, val = parser.read_filter(line)
                self.filters[key] = val

            elif line.startswith('##FORMAT'):
                key, val = parser.read_format(line)
                self.formats[key] = val

            elif line.startswith('##contig'):
                key, val = parser.read_contig(line)
                self.contigs[key] = val

            else:
                key, val = parser.read_meta(line.strip())
                self.metadata[key] = val

            line = self.reader.next()

        if line.startswith('#'):  # the column def'n line - REQ'D
            self._col_defn_line = line
            self._header_lines.append(line)
            fields = line.rstrip().split("\t")
            self.samples = fields[9:]
            self.num_samples = len(self.samples)
            self._sample_indexes = dict([(x,i) for (i,x) in enumerate(self.samples)])
        else:
             sys.exit("Expected column definition line beginning with #.  Not found - exiting. ({})".format(line))


    cdef list _map(Reader self, func, iterable, char *bad='.'):
        '''``map``, but make bad values None.'''
        return [func(x) if x != bad else None for x in iterable]


    def _parse_info(self, info_str):
        '''Parse the INFO field of a VCF entry into a dictionary of Python
        types.

        '''
        if info_str == '.':
            return {}

        cdef list entries = info_str.split(';')
        cdef dict retdict = {}

        cdef int i = 0
        cdef int n = len(entries)
        cdef char *entry_type
        cdef list entry
        # for entry in entries:
        for i in xrange(n):
            entry = entries[i].split('=')
            # entry = entry.split('=')
            ID = entry[0]
            if ID in self.infos:
                entry_type = self.infos[ID].type
            elif ID in RESERVED_INFO:
                entry_type = RESERVED_INFO[ID]
            else:
                if len(entry) == 1:
                    entry_type = 'Flag'
                else:
                    entry_type = 'String'

            if entry_type == b'Integer':
                vals = entry[1].split(',')
                try:
                    val = _map(int, vals)
                except ValueError:
                    val = _map(float, vals)
            elif entry_type == b'Float':
                vals = entry[1].split(',')
                val = _map(float, vals)
            elif entry_type == b'Flag':
                val = True
            elif entry_type == b'String':
                if len(entry) > 1:
                    val = entry[1]
                else:
                    val = True
            elif entry_type == b'Character':
                val = entry[1]
            else:
                print >>sys.stderr, "XXXXXXXXXXXXXXXX"
                print >>sys.stderr, entry_type, entry

            try:
                if isinstance(val, list) and self.infos[ID].num == 1 and entry_type != b'String':
                    val = val[0]
            except KeyError:
                pass

            retdict[ID] = val

        return retdict


    def _parse_samples(self, Record rec, list samples, char *samp_fmt_s):
        '''Parse a sample entry according to the format specified in the FORMAT
        column.'''
        cdef list samp_fmt = samp_fmt_s.split(':')
        cdef int n = len(samp_fmt)
        cdef list samp_fmt_types = [None] * n
        cdef list samp_fmt_nums = [None] * n

        cdef int i = 0
        cdef char *fmt
        # for fmt in samp_fmt:
        for i in xrange(n):
            fmt = samp_fmt[i]
            try:
                entry_type = self.formats[fmt].type
                entry_num = self.formats[fmt].num
            except KeyError:
                entry_num = None
                try:
                    entry_type = RESERVED_FORMAT[fmt]
                except KeyError:
                    entry_type = 'String'
            samp_fmt_types[i] = entry_type
            samp_fmt_nums[i] = entry_num

        cdef int num_hom_ref = 0
        cdef int num_het = 0
        cdef int num_hom_alt = 0
        cdef int num_unknown = 0
        cdef int num_called = 0
        rec.samples  = [None] * self.num_samples# list of _Call objects for each sample
        rec.gt_bases = [None] * self.num_samples# A/A, A|G, G/G, etc.
        rec.gt_types   = [None] * self.num_samples# 0, 1, 2, etc.
        rec.gt_phases  = [None] * self.num_samples# T, F, T, etc.
        rec.gt_depths  = [None] * self.num_samples# 10, 37, 0, etc.
        rec.gt_ref_depths  = [None] * self.num_samples# 3, 32, 0, etc.
        rec.gt_alt_depths  = [None] * self.num_samples# 7, 5, 0, etc.
        rec.gt_quals  = [None] * self.num_samples# 10, 30, 20, etc.
        rec.gt_copy_numbers  = [None] * self.num_samples# 2, 1, 4, etc.
        rec.gt_phred_likelihoods = [None] * self.num_samples

        for i in xrange(self.num_samples):

            call = _parse_sample(samples[i], samp_fmt, \
                                 samp_fmt_types, samp_fmt_nums,
                                 self.samples[i], rec)

            rec.samples[i] = call

            alleles = call.gt_bases
            type = call.gt_type

            # add to the "all-samples" lists of GT info
            if alleles is not None:
                rec.gt_bases[i] = alleles
                rec.gt_types[i] = type if type is not None else 2
            else:
                rec.gt_bases[i] = './.'
                rec.gt_types[i] = 2
            rec.gt_phases[i] = call.phased
            rec.gt_depths[i] = call.gt_depth
            rec.gt_ref_depths[i] = call.gt_ref_depth
            rec.gt_alt_depths[i] = call.gt_alt_depth
            rec.gt_quals[i] = call.gt_qual
            rec.gt_copy_numbers[i] = call.gt_copy_number
            rec.gt_phred_likelihoods[i] = call.gt_phred_likelihoods

            # 0 / 00000000 hom ref
            # 1 / 00000001 het
            # 2 / 00000010 missing
            # 3 / 00000011 hom alt

            # tally the appropriate GT count
            if type == HOM_REF: num_hom_ref += 1
            elif type == HET: num_het += 1
            elif type == HOM_ALT: num_hom_alt += 1
            elif type == None: num_unknown += 1

        rec.num_called = num_hom_ref + num_het + num_hom_alt
        rec.num_hom_alt = num_hom_alt
        rec.num_het = num_het
        rec.num_hom_ref = num_hom_ref
        rec.num_unknown = num_unknown

    def __next__(self):
        '''Return the next record in the file.'''
        line = self.reader.next().rstrip()
        return self.parse(line)

    def parse(self, line):
        '''Return the next record in the file.'''
        cdef list row = line.split('\t')

        #CHROM
        cdef bytes chrom = row[0]
        if self._prepend_chr:
            chrom = 'chr' + str(chrom)
        # POS
        cdef int pos = int(row[1])
        # ID
        cdef bytes id = row[2]
        #REF
        cdef bytes ref = row[3]
        #ALT
        cdef list alt = self._map(str, row[4].split(','))
        #QUAL
        cdef object qual
        if row[5] == b'.':
            qual = None
        else:
            qual = float(row[5])
        #FILT
        cdef object filt = row[6].split(';') if ';' in row[6] else row[6]
        if filt == b'PASS' or filt == b'.':
             filt = None
        #INFO
        cdef dict info = self._parse_info(row[7])
        #FORMAT
        cdef bytes fmt
        try:
            fmt = row[8]
        except IndexError:
            fmt = None

        rec = Record(chrom, pos, id, ref, alt, qual, filt, info, fmt, self._sample_indexes)

        # collect GENOTYPE information for the current VCF record 
        if fmt is not None:
            self._parse_samples(rec, row[9:], fmt)
        return rec

    def fetch(self, chrom, start, end=None):
        """ fetch records from a Tabix indexed VCF, requires pysam
            if start and end are specified, return iterator over positions
            if end not specified, return individual ``_Call`` at start or None
        """
        if not pysam:
            raise Exception('pysam not available, try "pip install pysam"?')

        if not self.filename:
            raise Exception('Please provide a filename (or a "normal" fsock)')

        if not self._tabix:
            self._tabix = pysam.Tabixfile(self.filename)

        if self._prepend_chr and chrom[:3] == 'chr':
            chrom = chrom[3:]

        # not sure why tabix needs position -1
        start = start - 1

        if end is None:
            self.reader = self._tabix.fetch(chrom, start, start+1)
            try:
                return self.next()
            except StopIteration:
                return None

        self.reader = self._tabix.fetch(chrom, start, end)
        return self

    #we set the default for header_type to info for legacy reasons
    def add_info_header(self, name, num, type, desc):
        """Convenience method for adding a new header"""
        self.infos[name] = Info(name, num, type, desc)

    def add_filter_header(self, name, desc):
        """Convenience method for adding a new header"""
        self.filters[name] = Filter(name, desc)

class Writer(object):
    """ VCF Writer """

    fixed_fields = "#CHROM POS ID REF ALT QUAL FILTER INFO FORMAT".split()

    def __init__(self, stream, template):
        self.stream = stream
        self.writer = csv.writer(stream, delimiter="\t", lineterminator="\n")
        self.template = template

        for line in template.metadata.items():
            stream.write('##%s=%s\n' % line)
        for line in template.infos.values():
            stream.write('##INFO=<ID=%s,Number=%s,Type=%s,Description="%s">\n' % tuple(self._map(str, line)))
        for line in template.formats.values():
            stream.write('##FORMAT=<ID=%s,Number=%s,Type=%s,Description="%s">\n' % tuple(self._map(str, line)))
        for line in template.filters.values():
            stream.write('##FILTER=<ID=%s,Description="%s">\n' % tuple(self._map(str, line)))
        for line in template.contigs.values():
            text = '##contig=<ID={}'.format(line.id)

            if line.length is not None:
                text += ',length={}>\n'.format(line.length)
            else:
                text += '>\n'

            stream.write(text)

        self._write_header()

    def _write_header(self):
        # TODO: write INFO, etc
        self.writer.writerow(self.fixed_fields + self.template.samples)

    def write_record(self, record):
        """ write a record to the file """
        ffs = self._map(str, [record.CHROM, record.POS, record.ID, record.REF]) \
              + [self._format_alt(record.ALT), self._format_qual(record.QUAL), self._format_filter(record.FILTER) or 'PASS',
                 self._format_info(record.INFO), record.FORMAT]

        samples = [self._format_sample(record.FORMAT, sample)
            for sample in record.samples]
        self.writer.writerow(ffs + samples)

    def _format_alt(self, alt):
        return ','.join([x or '.' for x in alt])

    def _format_qual(self, qual):
        #strip off superfluous .0 to match what's in the test vcfs
        #maybe we should just store the original text on the class?
        return str(qual).rstrip('0').rstrip('.') if qual is not None else '.'

    #duplicated _format code from above, true for all these methods
    def _format_filter(self, filt):
        if filt is None:
            return None

        if isinstance(filt, basestring):
            return filt

        #filter is not empty or a string so we assume it's a list
        return ';'.join(filt)

    def _format_info(self, info):
        if not info:
            return '.'

        formatted = []
        for k, v in info.items():
            #values of type flag do not have a value, their presence implies True.
            #make sure the key exists before we look up the type
            if k in self.template.infos and self.template.infos[k].type == 'Flag':
                formatted.append(k)
            else:
                formatted.append("{}={}".format(k, self._stringify(v)))

        return ';'.join(formatted)

        #return ';'.join("%s=%s" % (x, self._stringify(y)) for x, y in info.items())

    def _format_sample(self, fmt, sample):
        if sample.data.get("GT", None) is None and not sample.site.is_sv:
            return "./."
        return ':'.join(self._stringify(sample.data[f]) for f in fmt.split(':'))

    def _stringify(self, x, none='.'):
        if isinstance(x, list):
            return ','.join(self._map(str, x, none))
        return str(x) if x is not None else none

    def _map(self, func, iterable, none='.'):
        '''``map``, but make None values none.'''
        return [func(x) if x is not None else none
                for x in iterable]

def __update_readme():
    import sys, vcf
    file('README.rst', 'w').write(vcf.__doc__)

# backwards compatibility
VCFReader = Reader
VCFWriter = Writer
