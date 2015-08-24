#encoding: utf-8
require 'nokogiri'

module GitlabMarkdownHelper
  include Gitlab::Markdown
  include PreferencesHelper

  # Use this in places where you would normally use link_to(gfm(...), ...).
  #
  # It solves a problem occurring with nested links (i.e.
  # "<a>outer text <a>gfm ref</a> more outer text</a>"). This will not be
  # interpreted as intended. Browsers will parse something like
  # "<a>outer text </a><a>gfm ref</a> more outer text" (notice the last part is
  # not linked any more). link_to_gfm corrects that. It wraps all parts to
  # explicitly produce the correct linking behavior (i.e.
  # "<a>outer text </a><a>gfm ref</a><a> more outer text</a>").
  def link_to_gfm(body, url, html_options = {})
    return "" if body.blank?

    escaped_body = if body =~ /\A\<img/
                     body
                   else
                     escape_once(body)
                   end

    gfm_body = gfm(escaped_body, {}, html_options)

    fragment = Nokogiri::XML::DocumentFragment.parse(gfm_body)
    if fragment.children.size == 1 && fragment.children[0].name == 'a'
      # Fragment has only one node, and it's a link generated by `gfm`.
      # Replace it with our requested link.
      text = fragment.children[0].text
      fragment.children[0].replace(link_to(text, url, html_options))
    else
      # Traverse the fragment's first generation of children looking for pure
      # text, wrapping anything found in the requested link
      fragment.children.each do |node|
        next unless node.text?
        node.replace(link_to(node.text, url, html_options))
      end
    end

    fragment.to_html.html_safe
  end

  MARKDOWN_OPTIONS = {
    no_intra_emphasis:   true,
    tables:              true,
    fenced_code_blocks:  true,
    strikethrough:       true,
    lax_spacing:         true,
    space_after_headers: true,
    superscript:         true,
    footnotes:           true
  }.freeze

  def markdown(text, options={})
    unless @markdown && options == @options
      @options = options

      # see https://github.com/vmg/redcarpet#darling-i-packed-you-a-couple-renderers-for-lunch
      rend = Redcarpet::Render::GitlabHTML.new(self, user_color_scheme_class, options)

      # see https://github.com/vmg/redcarpet#and-its-like-really-simple-to-use
      @markdown = Redcarpet::Markdown.new(rend, MARKDOWN_OPTIONS)
    end

    @markdown.render(text).html_safe
  end

  def asciidoc(text)
    Gitlab::Asciidoc.render(text, {
      commit: @commit,
      project: @project,
      project_wiki: @project_wiki,
      requested_path: @path,
      ref: @ref
    })
  end

  # Return the first line of +text+, up to +max_chars+, after parsing the line
  # as Markdown.  HTML tags in the parsed output are not counted toward the
  # +max_chars+ limit.  If the length limit falls within a tag's contents, then
  # the tag contents are truncated without removing the closing tag.
  def first_line_in_markdown(text, max_chars = nil, options = {})
    md = markdown(text, options).strip

    truncate_visible(md, max_chars || md.length) if md.present?
  end

  def render_wiki_content(wiki_page)
    case wiki_page.format
    when :markdown
      markdown(wiki_page.content)
    when :asciidoc
      asciidoc(wiki_page.content)
    else
      wiki_page.formatted_content.html_safe
    end
  end

  MARKDOWN_TIPS = [
    "行中断（软换行）是在行尾使用两个或更多的空格",
    "可以用 `英文反引号包围` 来内嵌代码",
    "使用三个 ``` 英文反引号或行首四个空格来声明代码块",
    "可以使用 :emoji_name: 代码来插入 Emoji 表情，比如 :thumbsup:",
    "使用 @user_name 通知其他参与者",
    "使用 @group_name 通知指定的群组",
    "使用 @all 通知整个团队",
    "使用英文 # 井号引用指定 id 的问题，比如 #123",
    "使用英文 ! 感叹号引用指定 id 的合并请求，比如 !123",
    "使用英文 *星号* or _下划线_ 标记指定的单词或短语为斜体",
    "使用英文 **双星号** 或 __双下划线__ 标记指定的单词或短语为粗体",
    "使用英文 ~~双波浪号~~ 标记指定的单词或短语为删除线",
    "可以在行首使用英文 + 加号、- 减号 或 * 星号标记一个带符号列表",
    "可以在行首使用英文 > 大于号表示引用",
    "使用三个或更多的英文 --- 减号、*** 星号或 ___ 下划线来标记一个横线"
  ].freeze

  # Returns a random markdown tip for use as a textarea placeholder
  def random_markdown_tip
    MARKDOWN_TIPS.sample
  end

  private

  # Return +text+, truncated to +max_chars+ characters, excluding any HTML
  # tags.
  def truncate_visible(text, max_chars)
    doc = Nokogiri::HTML.fragment(text)
    content_length = 0
    truncated = false

    doc.traverse do |node|
      if node.text? || node.content.empty?
        if truncated
          node.remove
          next
        end

        # Handle line breaks within a node
        if node.content.strip.lines.length > 1
          node.content = "#{node.content.lines.first.chomp}..."
          truncated = true
        end

        num_remaining = max_chars - content_length
        if node.content.length > num_remaining
          node.content = node.content.truncate(num_remaining)
          truncated = true
        end
        content_length += node.content.length
      end

      truncated = truncate_if_block(node, truncated)
    end

    doc.to_html
  end

  # Used by #truncate_visible.  If +node+ is the first block element, and the
  # text hasn't already been truncated, then append "..." to the node contents
  # and return true.  Otherwise return false.
  def truncate_if_block(node, truncated)
    if node.element? && node.description.block? && !truncated
      node.content = "#{node.content}..." if node.next_sibling
      true
    else
      truncated
    end
  end

  # Returns the text necessary to reference `entity` across projects
  #
  # project - Project to reference
  # entity  - Object that responds to `to_reference`
  #
  # Examples:
  #
  #   cross_project_reference(project, project.issues.first)
  #   # => 'namespace1/project1#123'
  #
  #   cross_project_reference(project, project.merge_requests.first)
  #   # => 'namespace1/project1!345'
  #
  # Returns a String
  def cross_project_reference(project, entity)
    if entity.respond_to?(:to_reference)
      "#{project.to_reference}#{entity.to_reference}"
    else
      ''
    end
  end
end
