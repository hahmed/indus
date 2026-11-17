p(/a{0,2}?/.match("aaa").to_a, /a{,2}/.match("aaa").to_a, /a{,2}?/.match("aaa").to_a, /a{2}?/.match("").to_a, /a{2}?/.match("aaa").to_a, /x{}/.match("x{}").to_a)
