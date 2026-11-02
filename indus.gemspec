Gem::Specification.new do |s|
  s.name        = "indus"
  s.version     = "0.0.1"
  s.summary     = "A more direct path from Ruby to machine code"
  s.description = "An experimental Ruby compiler: Ruby source -> SSA -> arm64. No C, no LLVM, no assembler, no linker."
  s.authors     = ["Haroon Ahmed"]
  s.homepage    = "https://github.com/hahmed/indus"
  s.license     = "MIT"
  s.files       = Dir["lib/**/*.rb", "lib/indus/runtime.s", "bin/*", "README.md"]
  s.executables = ["indus"]
  s.required_ruby_version = ">= 3.3"
  s.add_dependency "prism", "~> 1.8"
end
