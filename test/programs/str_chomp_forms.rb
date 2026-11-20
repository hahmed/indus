p "abc\r\n".chomp, "abc\r\n".chomp("\n"), "abc\r".chomp, "abc\n\r".chomp, "abc".chomp(""), "abc\n\n".chomp(""), "abc\r\n\r\n".chomp(""), "abc".chomp("bc")
