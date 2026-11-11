class K < StandardError; def message = "custom"; end
begin; raise K; rescue => e; p e.message; end
begin; raise K; rescue K => e; p e.message; end
