h = {a: 1, b: 2}
h.transform_values! { |v| v * 10 }
h.transform_keys!(&:to_s)
p h, h.rehash, {a: [1, 2]}.flatten(2), {a: nil, b: 1}.compact
h.select! { |k, v| v > 10 }
p h
