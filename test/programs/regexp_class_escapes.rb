p(/[\b]/.match("\b").to_a.map(&:ord), /[\D]+/.match("ab12").to_a, /[\W]/.match("a!").to_a, /[\x41-\x43]+/.match("xABCy").to_a, /[\h]+/.match("zz1aF9").to_a, /[^\S]/.match("a b").to_a)
