# frozen_string_literal: true

# Regexp literals, compiled at compile time into a small program for the backtracking
# matcher in lib/indus/rt/regex.rb. The program is an integer array (one constant per
# literal); the matcher walks it with an explicit backtrack stack.
#
# Supported: literals, ., [classes] with ranges and negation, \d \w \s \D \W \S \b \B,
# anchors ^ $ \A \z \Z, groups ( ) (?: ), alternation |, quantifiers * + ? {m} {m,} {m,n}
# with lazy variants, the i flag, and backreferences \1..\9 in the pattern. Everything else
# (lookaround, named groups, unicode classes, x/m flags) refuses with the construct named.
#
# Program ops (each op is OP, then its operands; all ints):
#   0 CHAR c          match byte c (case-folded when the i flag is set, both sides)
#   1 ANY             any byte but newline
#   2 CLASS n neg b0 b1 ... b(n*2-1)  n byte ranges [lo, hi]; neg 1 = negated
#   3 SPLIT a b       try a first, then b (relative offsets from the op's position)
#   4 JMP a
#   5 SAVE k          position into capture slot k (2*group, 2*group+1)
#   6 MATCH
#   7 BOL  8 EOL  9 BOS  10 EOS  11 WORDB  12 NWORDB  13 EOSNL (\Z)
#   14 BACKREF g
module Indus
  module Regex
    OPS = { char: 0, any: 1, cls: 2, split: 3, jmp: 4, save: 5, match: 6, bol: 7, eol: 8, bos: 9, eos: 10,
            wordb: 11, nwordb: 12, eosnl: 13, backref: 14 }.freeze

    class Node
      attr_accessor :kind, :a, :b, :min, :max, :greedy, :neg, :ranges, :index
      def initialize(kind, **kw) = (@kind = kind; kw.each { |k, v| instance_variable_set(:"@#{k}", v) })
    end

    def self.compile(source, flags = "")
      p = Parser.new(source, flags.include?("i"))
      ast = p.parse
      c = Compiler.new(p.ngroups, flags.include?("i"))
      c.emit_node(ast)
      c.code << OPS[:match]
      [c.code, p.ngroups, p.names || []]
    end

    class Parser
      attr_reader :ngroups
      def initialize(src, icase)
        @s = src.bytes; @i = 0; @ngroups = 0; @icase = icase
      end

      def parse
        n = alt
        raise "regexp: unexpected #{@s[@i].chr.inspect} at #{@i} in /#{@s.pack('C*')}/" if @i < @s.size
        n
      end

      def peek = @s[@i]
      def take = (c = @s[@i]; @i += 1; c)
      def eat(ch) = (peek == ch.ord ? (take; true) : false)

      def alt
        left = seq
        while eat("|")
          right = seq
          left = Node.new(:alt, a: left, b: right)
        end
        left
      end

      def seq
        items = []
        items << quant while peek && peek != "|".ord && peek != ")".ord
        Node.new(:seq, a: items)
      end

      def quant
        atom = atom_node
        loop do
          min = max = nil
          if eat("*") then min, max = 0, -1
          elsif eat("+") then min, max = 1, -1
          elsif eat("?") then min, max = 0, 1
          elsif peek == "{".ord && (m = @s[@i..].pack("C*").match(/\A\{(\d+)(,(\d*))?\}/))
            @i += m[0].bytesize
            min = m[1].to_i; max = m[2].nil? ? min : (m[3].empty? ? -1 : m[3].to_i)
          else break end
          greedy = !eat("?")
          atom = Node.new(:rep, a: atom, min: min, max: max, greedy: greedy)
        end
        atom
      end

      def atom_node
        c = take
        case c.chr
        when "(" then group
        when "[" then klass
        when "." then Node.new(:any)
        when "^" then Node.new(:bol)
        when "$" then Node.new(:eol)
        when "\\" then escape
        when "*", "+", "?" then raise "regexp: nothing to repeat at #{@i - 1}"
        else Node.new(:char, a: c)
        end
      end

      attr_reader :names # capture index -> name (nil for unnamed), index 0 unused
      def group
        if eat("?")
          if eat(":") then capture = false
          elsif eat("<") && @s[@i] != 61 && @s[@i] != 33 # (?<name>...) -- not lookbehind (?<= (?<!
            nm = +""; nm << @s[@i].chr && (@i += 1) while @i < @s.size && @s[@i] != 62
            raise "regexp: unterminated group name" unless eat(">")
            capture = true; @ngroups += 1; idx = @ngroups; (@names ||= [])[idx] = nm
          else
            bad = @s[@i..].pack("C*")[0, 3]
            raise "regexp: (?#{bad}... is not supported (only (?:...) and (?<name>...) groups; no lookaround)"
          end
        else
          capture = true; @ngroups += 1; idx = @ngroups
        end
        inner = alt
        raise "regexp: missing )" unless eat(")")
        capture ? Node.new(:group, a: inner, index: idx) : inner
      end

      def escape
        c = take or raise "regexp: trailing backslash"
        case c.chr
        when "d" then Node.new(:cls, ranges: [[48, 57]], neg: false)
        when "D" then Node.new(:cls, ranges: [[48, 57]], neg: true)
        when "w" then Node.new(:cls, ranges: WORD, neg: false)
        when "W" then Node.new(:cls, ranges: WORD, neg: true)
        when "s" then Node.new(:cls, ranges: SPACE, neg: false)
        when "S" then Node.new(:cls, ranges: SPACE, neg: true)
        when "b" then Node.new(:wordb)
        when "B" then Node.new(:nwordb)
        when "A" then Node.new(:bos)
        when "z" then Node.new(:eos)
        when "Z" then Node.new(:eosnl)
        when "n" then Node.new(:char, a: 10)
        when "t" then Node.new(:char, a: 9)
        when "r" then Node.new(:char, a: 13)
        when "1".."9" then Node.new(:backref, a: c - 48)
        when "h", "H", "p", "P", "u", "x", "k", "g", "R", "X" then raise "regexp: \\#{c.chr} is not supported"
        else Node.new(:char, a: c) # an escaped metacharacter
        end
      end

      WORD = [[48, 57], [65, 90], [95, 95], [97, 122]].freeze
      SPACE = [[9, 13], [32, 32]].freeze

      def klass
        neg = eat("^")
        ranges = []
        first = true
        loop do
          c = take or raise "regexp: missing ]"
          break if c == "]".ord && !first
          first = false
          if c == "\\".ord
            e = take
            case e.chr
            when "d" then ranges << [48, 57]; next
            when "w" then ranges.concat(WORD); next
            when "s" then ranges.concat(SPACE); next
            when "n" then c = 10
            when "t" then c = 9
            when "D", "W", "S" then raise "regexp: \\#{e.chr} inside [...] is not supported"
            else c = e
            end
          end
          if peek == "-".ord && @s[@i + 1] && @s[@i + 1] != "]".ord
            take
            hi = take
            hi = take if hi == "\\".ord
            ranges << [c, hi]
          else
            ranges << [c, c]
          end
        end
        Node.new(:cls, ranges: ranges, neg: neg)
      end
    end

    class Compiler
      attr_reader :code
      def initialize(ngroups, icase) = (@code = []; @ngroups = ngroups; @icase = icase)

      def emit_node(n)
        case n.kind
        when :seq then n.a.each { emit_node(_1) }
        when :char
          c = n.a
          if @icase && ((65..90).include?(c) || (97..122).include?(c))
            lo = c | 32
            @code << OPS[:cls] << 2 << 0 << lo << lo << (lo - 32) << (lo - 32)
          else
            @code << OPS[:char] << c
          end
        when :any then @code << OPS[:any]
        when :cls
          rs = n.ranges
          rs = rs.flat_map { |(lo, hi)| fold_range(lo, hi) } if @icase
          @code << OPS[:cls] << rs.size << (n.neg ? 1 : 0)
          rs.each { |(lo, hi)| @code << lo << hi }
        when :bol then @code << OPS[:bol]
        when :eol then @code << OPS[:eol]
        when :bos then @code << OPS[:bos]
        when :eos then @code << OPS[:eos]
        when :eosnl then @code << OPS[:eosnl]
        when :wordb then @code << OPS[:wordb]
        when :nwordb then @code << OPS[:nwordb]
        when :backref then @code << OPS[:backref] << n.a
        when :group
          @code << OPS[:save] << n.index * 2
          emit_node(n.a)
          @code << OPS[:save] << n.index * 2 + 1
        when :alt
          split_at = @code.size; @code << OPS[:split] << 0 << 0
          emit_node(n.a)
          jmp_at = @code.size; @code << OPS[:jmp] << 0
          @code[split_at + 2] = @code.size - split_at
          emit_node(n.b)
          @code[jmp_at + 1] = @code.size - jmp_at
          @code[split_at + 1] = 3
        when :rep
          min, max, g = n.min, n.max, n.greedy
          min.times { emit_node(n.a) }
          if max == -1
            # L: split body, exit ; body ; jmp L
            l = @code.size; @code << OPS[:split] << 0 << 0
            emit_node(n.a)
            jmp_at = @code.size
            @code << OPS[:jmp] << (l - jmp_at)
            set_split(l, 3, @code.size - l, g)
          else
            (max - min).times do
              l = @code.size; @code << OPS[:split] << 0 << 0
              emit_node(n.a)
              set_split(l, 3, @code.size - l, g)
            end
          end
        else raise "regexp: unsupported node #{n.kind}"
        end
      end

      # a greedy split tries the body first; a lazy one tries the exit first
      def set_split(at, body, exit, greedy)
        @code[at + 1], @code[at + 2] = greedy ? [body, exit] : [exit, body]
      end

      def fold_range(lo, hi)
        out = [[lo, hi]]
        (lo..hi).each do |c|
          if (65..90).include?(c) then out << [c + 32, c + 32]
          elsif (97..122).include?(c) then out << [c - 32, c - 32] end
        end
        out
      end
    end
  end
end
