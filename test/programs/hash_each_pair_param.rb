{a: 1, b: 2}.each { |pair| p pair }
{a: 1}.each { |pair| p pair[0], pair[1] }
{a: 1}.map { |pair| pair }.then { p _1 }
