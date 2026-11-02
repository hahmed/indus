#!/usr/bin/env ruby
# The honest benchmark report. Per benchmark and system, separately:
#   compile  source -> executable, whole process (n/a for interpreters)
#   cold     launch -> exit of the compiled program, whole process, best of N
#   rss      peak resident set of that run (KB)
#   ok       output byte-identical to CRuby's; or why not
# AOT systems (Indus, Go, Rust) build and run inside one Linux container on
# this machine's cores (bench/ports/Dockerfile). CRuby, YJIT and Spinel run
# on the macOS host: Spinel emits Mach-O, and this Mac's policy agent will not
# execute binaries written by processes it does not recognise (ours).
# Steady-state JIT throughput is not measured: every program here is a cold
# run; YJIT's warm-up is inside its number.
#
#   bench/report.rb [bench...]   -> prints a markdown table, writes bench/REPORT.md
require "fileutils"

ROOT = File.expand_path("..", __dir__)
PORTS = File.join(ROOT, "bench/ports")
OUT = File.expand_path("~/tmp/report"); FileUtils.mkdir_p(OUT)
N = (ENV["N"] || 5).to_i
IMG = "indus-bench"
SPINEL = File.expand_path("~/src/github.com/matz/spinel/spinel")

benches = ARGV.empty? ? %w[fib binary_trees nbody shapes str_build wordfreq server range_each] : ARGV

def ms(t0) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
def sh(cmd) = system(cmd, out: File::NULL, err: File::NULL)
def timed(cmd) = (t = Process.clock_gettime(Process::CLOCK_MONOTONIC); ok = sh(cmd); [ms(t), ok])

# run inside the container, N times in one session: nanosecond wall clock
# per run (GNU date), peak RSS from GNU time on one run, output captured
def box_run(exe, args = "")
  script = <<~SH
    best=999999999
    for i in $(seq #{N}); do
      s=$(date +%s%N); /w/#{exe} #{args} > /tmp/out; e=$(date +%s%N)
      d=$(( (e - s) / 1000 )); [ $d -lt $best ] && best=$d
    done
    /usr/bin/time -f "%M" /w/#{exe} #{args} > /dev/null 2> /tmp/rss
    echo "__STATS $best $(cat /tmp/rss)"
    cat /tmp/out
  SH
  r = `podman run --rm -v #{OUT}:/w -v #{PORTS}:/p #{IMG} sh -c '#{script.gsub("'", "'\\''")}' 2>&1`
  stats, *body = r.lines
  _, us, kb = stats.split
  [(us.to_f / 1000).round(1), kb.to_i, body.join]
end

# compile inside the container, timed there (container startup excluded)
def box_compile(cmd)
  script = "s=$(date +%s%N); #{cmd} > /dev/null 2>&1; rc=$?; e=$(date +%s%N); echo \"__C $(( (e - s) / 1000000 )) $rc\""
  r = `podman run --rm -v #{OUT}:/w -v #{PORTS}:/p -e HOME=/tmp -e GOCACHE=/tmp/gocache #{IMG} sh -c '#{script}' 2>&1`
  l = r.lines.grep(/^__C/).first or return [nil, false]
  _, ms, rc = l.split
  [ms.to_f, rc == "0"]
end

def host_run(cmd)
  best = nil; out = nil
  N.times do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    o = `#{cmd} 2>/dev/null`
    best = [best, ms(t)].compact.min
    out ||= o
  end
  [best, nil, out]
end

rows = []
benches.each do |b|
  src = File.join(ROOT, "bench/#{b}.rb")
  expected = File.read(File.join(ROOT, "bench/#{b}.expected"))
  row = { bench: b }

  # ---- CRuby / YJIT (host, whole process; no compile step)
  %w[cruby yjit].each do |sys|
    flag = sys == "yjit" ? "--yjit" : ""
    cold, _, out = host_run("ruby --disable-gems #{flag} #{src}")
    row[sys] = { compile: nil, cold: cold, rss: nil, ok: out == expected }
  end

  # ---- Spinel (host): compile, then run its Mach-O
  exe = File.join(OUT, "spinel_#{b}")
  ct, ok = timed("#{SPINEL} #{src} -o #{exe}")
  if ok
    cold, _, out = host_run(exe)
    row["spinel"] = { compile: ct, cold: cold, rss: nil, ok: out == expected }
  else
    row["spinel"] = { compile: nil, cold: nil, rss: nil, ok: "refused" }
  end

  # ---- Indus: compile on host (the compiler is Ruby), run the ELF in the box
  ct, ok = timed("#{ROOT}/bin/indus #{src} -o #{OUT}/indus_#{b} --linux")
  if ok
    cold, rss, out = box_run("indus_#{b}")
    row["indus"] = { compile: ct, cold: cold, rss: rss, ok: out == expected }
  else
    row["indus"] = { compile: nil, cold: nil, rss: nil, ok: "unsupported" }
  end

  # ---- Go / Rust: compile and run in the box
  { "go" => "go build -o /w/go_#{b} /p/go/#{b}.go", "rust" => "rustc -O -o /w/rust_#{b} /p/rust/#{b}.rs" }.each do |sys, build|
    if File.exist?(File.join(PORTS, sys, "#{b}.#{sys == 'go' ? 'go' : 'rs'}"))
      ct, ok = box_compile(build)
      if ok
        cold, rss, out = box_run("#{sys}_#{b}")
        row[sys] = { compile: ct, cold: cold, rss: rss, ok: out == expected }
      else
        row[sys] = { compile: nil, cold: nil, rss: nil, ok: "build failed" }
      end
    else
      row[sys] = { compile: nil, cold: nil, rss: nil, ok: "no port" }
    end
  end
  rows << row
  $stderr.puts "#{b}: " + row.except(:bench).map { |s, r| "#{s}=#{r[:cold] || r[:ok]}" }.join(" ")
end

# ---- render
systems = %w[cruby yjit spinel indus go rust]
fmt = ->(v) { v.nil? ? "–" : v.is_a?(Float) ? "#{v} ms" : v.to_s }
okf = ->(v) { v == true ? "✓" : v == false ? "✗ output differs" : v.to_s }
md = +"# Benchmark report\n\n"
md << "Generated #{Time.now.strftime('%Y-%m-%d %H:%M')} on #{`sysctl -n machdep.cpu.brand_string`.strip}, macOS #{`sw_vers -productVersion`.strip}. "
md << "Best of #{N} runs. #{`ruby -v`.strip}. #{`#{SPINEL} --version`.strip}. "
md << `podman run --rm #{IMG} sh -c 'go version; rustc --version'`.lines.map(&:strip).join(", ") << ".\n\n"
md << "**Read the columns separately.** `compile` is source→executable. `cold` is launch→exit of the whole process (for CRuby/YJIT that is the interpreter, with JIT warm-up inside). "
md << "`rss` is peak resident memory of that run. CRuby, YJIT and Spinel ran on the macOS host; Indus, Go and Rust ran as Linux binaries in one container on the same cores (see bench/report.rb for why). "
md << "Go and Rust ports are in bench/ports and follow the Ruby program's allocation pattern and 64-bit integer semantics; no fast-math.\n\n"
%i[cold compile rss].each do |col|
  md << "## #{col}\n\n| bench | " << systems.join(" | ") << " |\n|---|" << "---|" * systems.size << "\n"
  rows.each do |r|
    md << "| #{r[:bench]} | " << systems.map { |s| x = r[s]; x[col].nil? && x[:ok] != true ? okf.(x[:ok]) : fmt.(x[col]) }.join(" | ") << " |\n"
  end
  md << "\n"
end
md << "## correctness\n\n| bench | " << systems.join(" | ") << " |\n|---|" << "---|" * systems.size << "\n"
rows.each { |r| md << "| #{r[:bench]} | " << systems.map { |s| okf.(r[s][:ok]) }.join(" | ") << " |\n" }
md << "\nIndus memory tiers and collector: `HEAP=1 bin/indus bench/<b>.rb` reports heap use and collections (not part of this table).\n"
File.write(File.join(ROOT, "bench/REPORT.md"), md)
puts md
