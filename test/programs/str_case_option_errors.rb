p "aBc".downcase(:ascii), "x".downcase(:fold)
begin; "abc".capitalize(:fold); rescue ArgumentError => e; p e.message; end
begin; "abc".upcase(:bogus); rescue ArgumentError => e; p e.message; end
