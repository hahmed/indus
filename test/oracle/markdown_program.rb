# a markdown-ish formatter: string building, regexps, each_line, heredoc-free
class Doc
  def initialize(text)
    @lines = text.split("\n")
  end
  def to_html
    out = []
    in_list = false
    @lines.each do |line|
      case line
      when /^### (.+)/ then out << "<h3>#{$1}</h3>"
      when /^## (.+)/ then out << "<h2>#{$1}</h2>"
      when /^# (.+)/ then out << "<h1>#{$1}</h1>"
      when /^[-*] (.+)/
        out << "<ul>" unless in_list
        in_list = true
        out << "  <li>#{inline($1)}</li>"
      when /^\s*$/
        if in_list
          out << "</ul>"
          in_list = false
        end
      else
        out << "<p>#{inline(line)}</p>"
      end
    end
    out << "</ul>" if in_list
    out.join("\n")
  end
  def inline(s)
    s.gsub(/\*\*(.+?)\*\*/, "<b>\\1</b>").gsub(/`([^`]+)`/, "<code>\\1</code>")
  end
end
src = "# Title\n\nSome **bold** text with `code`.\n\n- one\n- two **x**\n\n## Sub\nlast line"
puts Doc.new(src).to_html
puts "---"
puts Doc.new("").to_html.inspect
