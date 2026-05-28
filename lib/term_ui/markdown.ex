defmodule TermUI.Markdown do
  @moduledoc """
  Markdown processor for rendering styled text in TermUI.

  Converts markdown content to styled segments that can be rendered
  by TermUI components.

  ## Usage

      iex> lines = TermUI.Markdown.render("**bold** and *italic*", 80)

      iex> result = TermUI.Markdown.render_with_elements("```elixir\\ndef hello, do: :world\\n```", 80)
  """

  alias TermUI.CharacterSet
  alias TermUI.Component.RenderNode
  alias TermUI.Renderer.DisplayWidth
  alias TermUI.Renderer.Style

  # GitHub-Flavored Markdown extensions: strikethrough (~~text~~), tables,
  # task lists ([x]/[ ]), and autolinks. Matches how most LLM and assistant
  # outputs format markdown. Callers that want vanilla CommonMark can pass
  # `gfm: false`.
  @gfm_mdex_opts [extension: [strikethrough: true, table: true, tasklist: true, autolink: true]]

  @type styled_segment :: {String.t(), Style.t() | nil}
  @type styled_line :: [styled_segment]

  @type interactive_element :: %{
          id: String.t(),
          type: :code_block,
          content: String.t(),
          language: String.t() | nil,
          start_line: non_neg_integer(),
          end_line: non_neg_integer()
        }

  @type render_result :: %{
          lines: [styled_line()],
          elements: [interactive_element()],
          content_height: non_neg_integer()
        }

  # Style definitions
  @header1_style Style.new(fg: :cyan, attrs: [:bold])
  @header2_style Style.new(fg: :cyan, attrs: [:bold])
  @header3_style Style.new(fg: :white, attrs: [:bold])
  @bold_style Style.new(attrs: [:bold])
  @italic_style Style.new(attrs: [:italic])
  @code_style Style.new(fg: :yellow)
  @code_block_style Style.new(fg: :yellow)
  @code_border_style Style.new(fg: :bright_black)
  @code_border_focused_style Style.new(fg: :cyan, attrs: [:bold])
  @blockquote_style Style.new(fg: :bright_black)
  @link_style Style.new(fg: :blue, attrs: [:underline])
  @list_bullet_style Style.new(fg: :cyan)
  @hr_style Style.new(fg: :bright_black)
  @strikethrough_style Style.new(attrs: [:strikethrough])
  @task_marker_style Style.new(fg: :cyan)

  # Dialyzer: Pattern match coverage warnings
  @dialyzer {:nowarn_function,
             render: 2,
             render: 3,
             render_with_elements: 3,
             render_line_to_node: 1,
             process_document: 2,
             process_document_with_elements: 3}

  # Syntax highlighting token styles
  @token_styles %{
    keyword: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_namespace: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_pseudo: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_reserved: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_constant: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_declaration: Style.new(fg: :magenta, attrs: [:bold]),
    keyword_type: Style.new(fg: :magenta, attrs: [:bold]),
    string: Style.new(fg: :green),
    string_char: Style.new(fg: :green),
    string_doc: Style.new(fg: :green),
    string_double: Style.new(fg: :green),
    string_single: Style.new(fg: :green),
    string_sigil: Style.new(fg: :green),
    string_regex: Style.new(fg: :green),
    string_interpol: Style.new(fg: :red),
    string_escape: Style.new(fg: :cyan),
    string_symbol: Style.new(fg: :cyan),
    comment: Style.new(fg: :bright_black),
    comment_single: Style.new(fg: :bright_black),
    comment_multiline: Style.new(fg: :bright_black),
    comment_doc: Style.new(fg: :bright_black),
    atom: Style.new(fg: :cyan),
    number: Style.new(fg: :yellow),
    number_integer: Style.new(fg: :yellow),
    number_float: Style.new(fg: :yellow),
    number_bin: Style.new(fg: :yellow),
    number_oct: Style.new(fg: :yellow),
    number_hex: Style.new(fg: :yellow),
    operator: Style.new(fg: :yellow),
    operator_word: Style.new(fg: :magenta, attrs: [:bold]),
    name: Style.new(fg: :white),
    name_function: Style.new(fg: :blue),
    name_class: Style.new(fg: :yellow, attrs: [:bold]),
    name_builtin: Style.new(fg: :cyan),
    name_builtin_pseudo: Style.new(fg: :cyan),
    name_attribute: Style.new(fg: :cyan),
    name_label: Style.new(fg: :cyan),
    name_constant: Style.new(fg: :yellow, attrs: [:bold]),
    name_exception: Style.new(fg: :red),
    name_tag: Style.new(fg: :blue),
    name_decorator: Style.new(fg: :cyan),
    name_namespace: Style.new(fg: :yellow, attrs: [:bold]),
    punctuation: Style.new(fg: :white),
    whitespace: nil,
    text: nil
  }

  @supported_lexers %{
    "elixir" => Makeup.Lexers.ElixirLexer,
    "ex" => Makeup.Lexers.ElixirLexer,
    "exs" => Makeup.Lexers.ElixirLexer,
    "iex" => Makeup.Lexers.ElixirLexer,
    "erlang" => Makeup.Lexers.ErlangLexer,
    "erl" => Makeup.Lexers.ErlangLexer,
    "hrl" => Makeup.Lexers.ErlangLexer,
    "eex" => Makeup.Lexers.EExLexer,
    "heex" => Makeup.Lexers.HEExLexer,
    "html" => Makeup.Lexers.HTMLLexer,
    "htm" => Makeup.Lexers.HTMLLexer,
    "css" => MakeupCSS.Lexer,
    "json" => Makeup.Lexers.JsonLexer,
    "diff" => Makeup.Lexers.DiffLexer,
    "patch" => Makeup.Lexers.DiffLexer,
    "ts" => MakeupTS.Lexer,
    "typescript" => MakeupTS.Lexer,
    "tsx" => MakeupTS.Lexer,
    "js" => MakeupTS.Lexer,
    "javascript" => MakeupTS.Lexer,
    "jsx" => MakeupTS.Lexer,
    "sql" => MakeupSql,
    "c" => Makeup.Lexers.CLexer,
    "h" => Makeup.Lexers.CLexer,
    "rust" => Makeup.Lexers.RustLexer,
    "rs" => Makeup.Lexers.RustLexer
  }

  @doc """
  Renders markdown content as a list of styled lines.

  ## Options

  * `:compact` — when `true`, strips blank separator rows so blocks render
    adjacently. Default `false` (one blank row after every block, matching
    historical behaviour). Useful for embedding markdown into a denser host
    layout (e.g. chat scrollback) that supplies its own block separation.

  * `:gfm` — when `false`, disables GitHub-Flavored Markdown extensions
    (strikethrough, tables, task lists, autolinks). Default `true`.
  """
  @spec render(String.t(), pos_integer()) :: [styled_line()]
  def render(content, max_width), do: render(content, max_width, [])

  @spec render(String.t() | nil, pos_integer(), keyword()) :: [styled_line()]
  def render("", _max_width, _opts), do: [[{"", nil}]]
  def render(nil, _max_width, _opts), do: [[{"", nil}]]

  def render(content, max_width, opts)
      when is_binary(content) and max_width > 0 and is_list(opts) do
    case MDEx.parse_document(content, mdex_options(opts)) do
      {:ok, document} ->
        document
        |> process_document(max_width)
        |> maybe_compact(opts)
        |> wrap_styled_lines(max_width)

      {:error, _reason} ->
        content
        |> String.split("\n")
        |> Enum.map(fn line -> [{line, nil}] end)
        |> maybe_compact(opts)
        |> wrap_styled_lines(max_width)
    end
  end

  def render(content, _max_width, opts) when is_binary(content) and is_list(opts) do
    render(content, 80, opts)
  end

  defp mdex_options(opts) do
    if Keyword.get(opts, :gfm, true), do: @gfm_mdex_opts, else: []
  end

  defp maybe_compact(lines, opts) do
    if Keyword.get(opts, :compact, false) do
      Enum.reject(lines, &blank_line?/1)
    else
      lines
    end
  end

  defp blank_line?([{"", nil}]), do: true
  defp blank_line?([]), do: true
  defp blank_line?(_), do: false

  @doc """
  Renders markdown content with interactive element tracking.

  Same options as `render/3`. `:focused_element_id` selects which code-block
  element gets focus styling.
  """
  @spec render_with_elements(String.t() | nil, pos_integer(), keyword()) :: render_result()
  def render_with_elements("", _max_width, _opts) do
    %{lines: [[{"", nil}]], elements: [], content_height: 1}
  end

  def render_with_elements(nil, _max_width, _opts) do
    %{lines: [[{"", nil}]], elements: [], content_height: 1}
  end

  def render_with_elements(content, max_width, opts)
      when is_binary(content) and max_width > 0 and is_list(opts) do
    focused_id = Keyword.get(opts, :focused_element_id)

    case MDEx.parse_document(content, mdex_options(opts)) do
      {:ok, document} ->
        {raw_lines, raw_elements} =
          process_document_with_elements(document, max_width, focused_id)

        {compacted_lines, elements} =
          if Keyword.get(opts, :compact, false) do
            apply_compact_with_elements(raw_lines, raw_elements)
          else
            {raw_lines, raw_elements}
          end

        wrapped_lines = wrap_styled_lines(compacted_lines, max_width)
        %{lines: wrapped_lines, elements: elements, content_height: length(wrapped_lines)}

      {:error, _reason} ->
        lines =
          content
          |> String.split("\n")
          |> Enum.map(fn line -> [{line, nil}] end)
          |> maybe_compact(opts)
          |> wrap_styled_lines(max_width)

        %{lines: lines, elements: [], content_height: length(lines)}
    end
  end

  def render_with_elements(content, _max_width, opts)
      when is_binary(content) and is_list(opts) do
    render_with_elements(content, 80, opts)
  end

  # Strip blank rows and shift any element indices that pointed past them,
  # so `start_line`/`end_line` remain consistent with the rendered output.
  defp apply_compact_with_elements(raw_lines, elements) do
    {acc_lines_rev, blanks_through_idx, _} =
      raw_lines
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {line, idx}, {acc, acc_map, prev} ->
        if blank_line?(line) do
          new_count = prev + 1
          {acc, Map.put(acc_map, idx, new_count), new_count}
        else
          {[line | acc], Map.put(acc_map, idx, prev), prev}
        end
      end)

    compacted = Enum.reverse(acc_lines_rev)

    adjusted_elements =
      Enum.map(elements, fn elem ->
        shift_start = Map.get(blanks_through_idx, elem.start_line, 0)
        shift_end = Map.get(blanks_through_idx, elem.end_line, 0)

        %{
          elem
          | start_line: elem.start_line - shift_start,
            end_line: elem.end_line - shift_end
        }
      end)

    {compacted, adjusted_elements}
  end

  @doc """
  Converts a styled line to a TermUI render node.
  """
  @spec render_line_to_node(styled_line()) :: RenderNode.t()
  def render_line_to_node([]), do: RenderNode.text("", nil)

  def render_line_to_node([{text, style}]) do
    RenderNode.text(text, style)
  end

  def render_line_to_node(segments) when is_list(segments) do
    nodes =
      Enum.map(segments, fn {text, style} ->
        RenderNode.text(text, style)
      end)

    RenderNode.stack(:horizontal, nodes)
  end

  # Document Processing
  defp process_document(%MDEx.Document{nodes: nodes}, max_width) do
    Enum.flat_map(nodes, &process_node(&1, max_width))
  end

  defp process_document(_, _max_width), do: [[{"", nil}]]

  defp process_document_with_elements(%MDEx.Document{nodes: nodes}, max_width, focused_id) do
    {lines, elements, _line_idx} =
      Enum.reduce(nodes, {[], [], 0}, fn node, {acc_lines, acc_elements, line_idx} ->
        {node_lines, node_elements} =
          process_node_with_elements(node, max_width, line_idx, focused_id)

        new_line_idx = line_idx + length(node_lines)
        {acc_lines ++ node_lines, acc_elements ++ node_elements, new_line_idx}
      end)

    {lines, elements}
  end

  defp process_document_with_elements(_, _max_width, _focused_id), do: {[[{"", nil}]], []}

  defp process_node_with_elements(
         %MDEx.CodeBlock{literal: code, info: info},
         max_width,
         line_idx,
         focused_id
       ) do
    lang = if info && info != "", do: String.downcase(String.trim(info)), else: nil
    element_id = generate_element_id(code, line_idx)
    is_focused = element_id == focused_id
    border_style = if is_focused, do: @code_border_focused_style, else: @code_border_style
    focus_hint = if is_focused, do: " [c]", else: ""
    chars = CharacterSet.current_charset()

    {header_lines, footer_lines} =
      code_block_frame(chars, lang, focus_hint, max_width, border_style)

    code_lines = render_code_block(code, lang)
    lines = header_lines ++ code_lines ++ footer_lines

    element = %{
      id: element_id,
      type: :code_block,
      content: String.trim_trailing(code),
      language: lang,
      start_line: line_idx,
      end_line: line_idx + length(lines) - 1
    }

    {lines, [element]}
  end

  defp process_node_with_elements(node, max_width, _line_idx, _focused_id) do
    lines = process_node(node, max_width)
    {lines, []}
  end

  defp generate_element_id(content, line_idx) do
    :crypto.hash(:md5, "#{line_idx}:#{content}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  # Header + footer rows for a fenced code block. Header always carries a
  # trailing space before the fill dashes so the focus marker can't visually
  # glue onto the border; corner/line glyphs come from the active charset
  # so ASCII terminals get +/-/| instead of mojibake.
  defp code_block_frame(chars, lang, focus_hint, max_width, border_style) do
    label =
      cond do
        lang != nil ->
          chars.tl <> chars.h_line <> " " <> lang <> focus_hint <> " "

        focus_hint != "" ->
          chars.tl <> focus_hint <> " "

        true ->
          chars.tl
      end

    header_fill = max(max_width - DisplayWidth.string_width(label), 0)
    footer_fill = max(max_width - DisplayWidth.string_width(chars.bl), 0)

    header = [
      [{label, @code_block_style}, {String.duplicate(chars.h_line, header_fill), border_style}]
    ]

    footer = [
      [
        {chars.bl, @code_block_style},
        {String.duplicate(chars.h_line, footer_fill), border_style}
      ],
      [{"", nil}]
    ]

    {header, footer}
  end

  # Node Processing -- every block-level type takes max_width so containers
  # (BlockQuote, List, ListItem) can propagate it to nested blocks like
  # code blocks, HRs, and tables that need the panel width to size their
  # decorations.
  defp process_node(%MDEx.Heading{level: 1, nodes: children}, _max_width) do
    content = extract_text(children)
    [[{content, @header1_style}], [{"", nil}]]
  end

  defp process_node(%MDEx.Heading{level: 2, nodes: children}, _max_width) do
    content = extract_text(children)
    [[{content, @header2_style}], [{"", nil}]]
  end

  defp process_node(%MDEx.Heading{level: level, nodes: children}, _max_width) when level >= 3 do
    content = extract_text(children)
    [[{content, @header3_style}], [{"", nil}]]
  end

  defp process_node(%MDEx.Paragraph{nodes: children}, _max_width) do
    segments = process_inline_nodes(children)
    [segments, [{"", nil}]]
  end

  defp process_node(%MDEx.CodeBlock{literal: code, info: info}, max_width) do
    lang = if info && info != "", do: String.downcase(String.trim(info)), else: nil
    chars = CharacterSet.current_charset()

    {header_lines, footer_lines} =
      code_block_frame(chars, lang, "", max_width, @code_border_style)

    header_lines ++ render_code_block(code, lang) ++ footer_lines
  end

  defp process_node(%MDEx.Code{literal: code}, _max_width) do
    [[{"`" <> code <> "`", @code_style}]]
  end

  defp process_node(%MDEx.BlockQuote{nodes: children}, max_width) do
    children
    |> Enum.flat_map(&process_node(&1, max_width))
    |> Enum.map(fn segments ->
      case segments do
        [{text, _style} | rest] ->
          [{"│ " <> text, @blockquote_style} | rest]

        [] ->
          [{"│ ", @blockquote_style}]
      end
    end)
  end

  defp process_node(%MDEx.List{list_type: :bullet, nodes: items}, max_width) do
    items
    |> Enum.flat_map(fn item -> process_list_item(item, "• ", max_width) end)
    |> Kernel.++([[{"", nil}]])
  end

  defp process_node(%MDEx.List{list_type: :ordered, nodes: items, start: start}, max_width) do
    items
    |> Enum.with_index(start || 1)
    |> Enum.flat_map(fn {item, idx} -> process_list_item(item, "#{idx}. ", max_width) end)
    |> Kernel.++([[{"", nil}]])
  end

  defp process_node(%MDEx.ListItem{nodes: children}, max_width) do
    Enum.flat_map(children, &process_node(&1, max_width))
  end

  defp process_node(%MDEx.TaskItem{} = item, max_width) do
    process_list_item(item, "", max_width)
  end

  defp process_node(%MDEx.ThematicBreak{}, max_width) do
    chars = CharacterSet.current_charset()
    [[{String.duplicate(chars.h_line, max_width), @hr_style}], [{"", nil}]]
  end

  defp process_node(%MDEx.SoftBreak{}, _max_width), do: []
  defp process_node(%MDEx.LineBreak{}, _max_width), do: [[{"", nil}]]

  defp process_node(%MDEx.Table{nodes: rows, alignments: alignments}, max_width) do
    render_table(rows, alignments, max_width)
  end

  defp process_node(node, max_width) when is_map(node) do
    case Map.get(node, :nodes) do
      nil ->
        case Map.get(node, :literal) do
          nil -> []
          text -> [[{text, nil}]]
        end

      children ->
        Enum.flat_map(children, &process_node(&1, max_width))
    end
  end

  defp process_node(_, _max_width), do: []

  # Table rendering. Cells are processed through the same inline pipeline
  # as the rest of the document so bold/code/link/strikethrough inside a
  # cell keeps its styling. Column widths use terminal-column width (so
  # CJK and emoji align) and box glyphs come from the active charset.
  defp render_table(rows, alignments, max_width) do
    cell_grid =
      Enum.map(rows, fn %MDEx.TableRow{nodes: cells} ->
        Enum.map(cells, fn %MDEx.TableCell{nodes: inline} ->
          segments = process_inline_nodes(inline)
          # Width and plain text must come from the rendered segments, not a
          # parallel extract_text/1 pass: code spans render with surrounding
          # backticks and links can render a "(url)" suffix, so measuring the
          # raw text would undercount every such cell and break alignment.
          text = segments_text(segments)
          %{text: text, segments: segments, width: DisplayWidth.string_width(text)}
        end)
      end)

    col_widths = compute_col_widths(cell_grid)

    body =
      cond do
        col_widths == [] ->
          []

        table_width(col_widths) > max_width ->
          render_table_plain(cell_grid)

        true ->
          padded_alignments = pad_alignments(alignments, length(col_widths))
          render_table_box(rows, cell_grid, col_widths, padded_alignments)
      end

    body ++ [[{"", nil}]]
  end

  defp compute_col_widths(cell_grid) do
    ncols = cell_grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if ncols == 0 do
      []
    else
      for col <- 0..(ncols - 1)//1 do
        cell_grid
        |> Enum.map(fn row ->
          case Enum.at(row, col) do
            nil -> 0
            %{width: w} -> w
          end
        end)
        |> Enum.max(fn -> 0 end)
      end
    end
  end

  # Align MDEx's alignments list with the actual column count so trailing
  # columns don't get silently dropped by Enum.zip in data_line.
  defp pad_alignments(alignments, ncols) do
    given = length(alignments)

    cond do
      given == ncols -> alignments
      given > ncols -> Enum.take(alignments, ncols)
      true -> alignments ++ List.duplicate(:none, ncols - given)
    end
  end

  defp table_width(col_widths) do
    Enum.sum(col_widths) + 3 * length(col_widths) + 1
  end

  defp render_table_plain(cell_grid) do
    Enum.map(cell_grid, fn cells ->
      [{Enum.map_join(cells, " | ", & &1.text), nil}]
    end)
  end

  defp render_table_box(rows, cell_grid, col_widths, alignments) do
    chars = CharacterSet.current_charset()
    {header_cells, body_cell_rows} = split_table_header(cell_grid, rows)

    top = border_line(chars.tl, chars.t_down, chars.tr, col_widths, chars)
    bottom = border_line(chars.bl, chars.t_up, chars.br, col_widths, chars)
    body_lines = Enum.map(body_cell_rows, &data_line(&1, col_widths, alignments, chars))

    case {header_cells, body_cell_rows} do
      {nil, _} ->
        [top | body_lines] ++ [bottom]

      {cells, []} ->
        [top, data_line(cells, col_widths, alignments, chars), bottom]

      {cells, _} ->
        sep = border_line(chars.t_right, chars.cross, chars.t_left, col_widths, chars)
        [top, data_line(cells, col_widths, alignments, chars), sep | body_lines] ++ [bottom]
    end
  end

  defp split_table_header(cell_grid, rows) do
    case {rows, cell_grid} do
      {[%MDEx.TableRow{header: true} | _], [header | body]} ->
        {header, body}

      _ ->
        {nil, cell_grid}
    end
  end

  defp border_line(left, mid, right, col_widths, chars) do
    fills = Enum.map_join(col_widths, mid, fn w -> String.duplicate(chars.h_line, w + 2) end)
    [{left <> fills <> right, @code_border_style}]
  end

  defp data_line(cells, col_widths, alignments, chars) do
    ncols = length(col_widths)
    empty = %{text: "", segments: [], width: 0}

    padded_cells =
      (cells ++ List.duplicate(empty, max(ncols - length(cells), 0)))
      |> Enum.take(ncols)

    sep = chars.v_line

    cell_blocks =
      Enum.zip_with([padded_cells, col_widths, alignments], fn [cell, width, align] ->
        pad_cell_segments(cell, width, align)
      end)

    middle =
      cell_blocks
      |> Enum.intersperse([{" " <> sep <> " ", nil}])
      |> List.flatten()

    [{sep <> " ", nil} | middle] ++ [{" " <> sep, nil}]
  end

  defp pad_cell_segments(cell, width, align) do
    pad_len = max(width - cell.width, 0)

    cond do
      pad_len == 0 ->
        cell.segments

      align == :right ->
        [{String.duplicate(" ", pad_len), nil} | cell.segments]

      align == :center ->
        left = div(pad_len, 2)
        right = pad_len - left

        left_pad = if left > 0, do: [{String.duplicate(" ", left), nil}], else: []
        right_pad = if right > 0, do: [{String.duplicate(" ", right), nil}], else: []
        left_pad ++ cell.segments ++ right_pad

      true ->
        cell.segments ++ [{String.duplicate(" ", pad_len), nil}]
    end
  end

  # Code Block Rendering
  defp render_code_block(code, lang) do
    case Map.get(@supported_lexers, lang) do
      nil ->
        plain_code_lines(code)

      lexer ->
        try do
          highlighted_code_lines(code, lexer)
        rescue
          _ -> plain_code_lines(code)
        end
    end
  end

  defp plain_code_lines(code) do
    code
    |> String.trim_trailing()
    |> String.split("\n")
    |> Enum.map(fn line -> [{"│ " <> line, @code_block_style}] end)
  end

  defp highlighted_code_lines(code, lexer) do
    tokens = lexer.lex(code |> String.trim_trailing())

    {lines, current_line} =
      Enum.reduce(tokens, {[], []}, fn {type, _meta, text}, {lines, current} ->
        style = Map.get(@token_styles, type) || @code_block_style
        text_str = normalize_token_text(text)
        add_token_to_lines(text_str, style, lines, current)
      end)

    all_lines = finalize_code_lines(lines, current_line)

    Enum.map(all_lines, fn segments ->
      [{"│ ", @code_block_style} | segments]
    end)
  end

  defp add_token_to_lines(text, style, lines, current) do
    parts = String.split(text, "\n")

    case parts do
      [single] ->
        {lines, current ++ [{single, style}]}

      [first | rest] ->
        finished_line = current ++ [{first, style}]
        {middle_parts, [last]} = Enum.split(rest, -1)
        middle_lines = Enum.map(middle_parts, fn part -> [{part, style}] end)
        {lines ++ [finished_line] ++ middle_lines, [{last, style}]}
    end
  end

  defp finalize_code_lines(lines, []), do: lines
  defp finalize_code_lines(lines, current), do: lines ++ [current]

  defp normalize_token_text(text) when is_binary(text), do: text

  defp normalize_token_text(text) when is_list(text) do
    text
    |> List.flatten()
    |> Enum.map_join(fn
      char when is_integer(char) -> <<char::utf8>>
      str when is_binary(str) -> str
    end)
  end

  defp normalize_token_text(text), do: to_string(text)

  # Inline Node Processing
  defp process_inline_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.flat_map(&process_inline_node/1)
    |> merge_adjacent_segments()
  end

  defp process_inline_node(%MDEx.Text{literal: text}), do: [{text, nil}]

  defp process_inline_node(%MDEx.Strong{nodes: children}) do
    text = extract_text(children)
    [{text, @bold_style}]
  end

  defp process_inline_node(%MDEx.Emph{nodes: children}) do
    text = extract_text(children)
    [{text, @italic_style}]
  end

  defp process_inline_node(%MDEx.Code{literal: code}) do
    [{"`" <> code <> "`", @code_style}]
  end

  defp process_inline_node(%MDEx.Strikethrough{nodes: children}) do
    text = extract_text(children)
    [{text, @strikethrough_style}]
  end

  defp process_inline_node(%MDEx.Link{url: url, nodes: children}) do
    text = extract_text(children)

    if text == url do
      [{text, @link_style}]
    else
      [{text, @link_style}, {" (#{url})", Style.new(fg: :bright_black)}]
    end
  end

  defp process_inline_node(%MDEx.SoftBreak{}), do: [{" ", nil}]
  defp process_inline_node(%MDEx.LineBreak{}), do: [{"\n", nil}]

  defp process_inline_node(node) when is_map(node) do
    case Map.get(node, :literal) do
      nil ->
        case Map.get(node, :nodes) do
          nil -> []
          children -> process_inline_nodes(children)
        end

      text ->
        [{text, nil}]
    end
  end

  defp process_inline_node(_), do: []

  # List Processing
  defp process_list_item(%MDEx.ListItem{nodes: children}, prefix, max_width) do
    do_process_list_item(children, prefix, @list_bullet_style, max_width)
  end

  # GFM task items: the parent List passes its bullet/number prefix, but
  # we replace it with `[x] `/`[ ] ` so the checkbox state reads at the
  # left margin and continuation lines indent under the text, not under
  # the bullet that would otherwise have been there.
  defp process_list_item(%MDEx.TaskItem{checked: checked?, nodes: children}, _prefix, max_width) do
    marker = if checked?, do: "[x] ", else: "[ ] "
    do_process_list_item(children, marker, @task_marker_style, max_width)
  end

  defp do_process_list_item(children, prefix, prefix_style, max_width) do
    children
    |> Enum.flat_map(&process_node(&1, max_width))
    |> Enum.with_index()
    |> Enum.map(fn {segments, idx} ->
      process_list_line(segments, idx, prefix, prefix_style)
    end)
    |> Enum.reject(fn segments ->
      segments == [{"", nil}]
    end)
  end

  defp process_list_line(segments, 0, prefix, prefix_style) do
    case segments do
      [{text, style} | rest] ->
        [{prefix, prefix_style}, {text, style} | rest]

      [] ->
        [{prefix, prefix_style}]
    end
  end

  defp process_list_line(segments, _idx, prefix, _prefix_style) do
    indent = String.duplicate(" ", String.length(prefix))

    case segments do
      [{text, style} | rest] ->
        [{indent <> text, style} | rest]

      [] ->
        segments
    end
  end

  # Text Extraction
  defp extract_text(nodes) when is_list(nodes) do
    Enum.map_join(nodes, &extract_text/1)
  end

  defp extract_text(%{literal: text}) when is_binary(text), do: text
  defp extract_text(%{nodes: children}), do: extract_text(children)
  defp extract_text(_), do: ""

  # Flatten processed inline segments back to their visible text. Used by the
  # table renderer so the measured width matches exactly what is drawn.
  defp segments_text(segments) do
    Enum.map_join(segments, fn {text, _style} -> text end)
  end

  # Segment Merging
  defp merge_adjacent_segments([]), do: []

  defp merge_adjacent_segments(segments) do
    segments
    |> Enum.reduce([], fn {text, style}, acc ->
      case acc do
        [{prev_text, ^style} | rest] ->
          [{prev_text <> text, style} | rest]

        _ ->
          [{text, style} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Line Wrapping
  @spec wrap_styled_lines([styled_line()], pos_integer()) :: [styled_line()]
  def wrap_styled_lines(lines, max_width) do
    lines
    |> Enum.flat_map(fn line ->
      wrap_styled_line(line, max_width)
    end)
  end

  defp wrap_styled_line([], _max_width), do: [[]]

  defp wrap_styled_line(segments, max_width) do
    expanded_segments = expand_newlines_in_segments(segments)

    {current, wrapped} =
      Enum.reduce(expanded_segments, {[], []}, fn
        :newline, {current, acc} ->
          {[], acc ++ [Enum.reverse(current)]}

        segment, {current, acc} ->
          {[segment | current], acc}
      end)

    lines_from_newlines = wrapped ++ [Enum.reverse(current)]

    lines_from_newlines
    |> Enum.flat_map(fn line_segments ->
      wrap_segments_for_width(line_segments, max_width)
    end)
  end

  defp expand_newlines_in_segments(segments) do
    Enum.flat_map(segments, fn {text, style} ->
      expand_segment_newlines(text, style)
    end)
  end

  defp expand_segment_newlines(text, style) do
    if String.contains?(text, "\n") do
      text
      |> String.split("\n")
      |> Enum.intersperse(:newline)
      |> Enum.map(fn
        :newline -> :newline
        t -> {t, style}
      end)
    else
      [{text, style}]
    end
  end

  defp wrap_segments_for_width([], _max_width), do: [[]]

  defp wrap_segments_for_width(segments, max_width) do
    {lines, current_line, _current_width} =
      Enum.reduce(segments, {[], [], 0}, fn {text, style}, {lines, current, width} ->
        wrap_segment({text, style}, lines, current, width, max_width)
      end)

    all_lines = lines ++ [current_line]

    all_lines
    |> Enum.map(fn line ->
      case line do
        [] -> [{"", nil}]
        segments -> segments
      end
    end)
  end

  defp wrap_segment({text, style}, lines, current, width, max_width) do
    text_len = String.length(text)

    cond do
      text == "" ->
        {lines, current ++ [{text, style}], width}

      width + text_len <= max_width ->
        {lines, current ++ [{text, style}], width + text_len}

      true ->
        wrap_text_at_words(text, style, lines, current, width, max_width)
    end
  end

  defp wrap_text_at_words(text, style, lines, current, width, max_width) do
    words = String.split(text, ~r/(\s+)/, include_captures: true)

    Enum.reduce(words, {lines, current, width}, fn word, acc ->
      handle_wrap_word(word, style, acc, max_width)
    end)
  end

  defp handle_wrap_word("", _style, acc, _max_width), do: acc

  defp handle_wrap_word(word, style, {ls, cur, w}, max_width) do
    word_len = String.length(word)

    cond do
      w + word_len <= max_width ->
        {ls, cur ++ [{word, style}], w + word_len}

      word_len > max_width ->
        handle_long_word(word, style, ls, cur, w, max_width)

      String.trim(word) == "" ->
        {ls, cur, w}

      true ->
        {ls ++ [cur], [{word, style}], word_len}
    end
  end

  defp handle_long_word(word, style, ls, cur, w, max_width) do
    {new_lines, remainder} = break_long_word(word, style, max_width - w, max_width)

    if cur == [] do
      {ls ++ new_lines, [{remainder, style}], String.length(remainder)}
    else
      {ls ++ [cur] ++ new_lines, [{remainder, style}], String.length(remainder)}
    end
  end

  defp break_long_word(word, style, first_chunk_size, max_width) do
    first_chunk_size = max(first_chunk_size, 1)

    chunks =
      word
      |> String.graphemes()
      |> Enum.chunk_every(max_width)
      |> Enum.map(&Enum.join/1)

    case chunks do
      [] ->
        {[], ""}

      [only] ->
        {[], only}

      [first | rest] ->
        first_part = String.slice(first, 0, first_chunk_size)
        remainder_of_first = String.slice(first, first_chunk_size..-1//1)

        all_parts = [remainder_of_first | rest]

        lines =
          all_parts
          |> Enum.slice(0..-2//1)
          |> Enum.map(fn part -> [{part, style}] end)

        last = List.last(all_parts) || ""

        if first_part == "" do
          {lines, last}
        else
          {[[{first_part, style}]] ++ lines, last}
        end
    end
  end
end
