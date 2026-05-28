defmodule TermUI.MarkdownTest do
  use ExUnit.Case, async: true

  alias TermUI.Markdown

  describe "render/3 default (compact: false)" do
    test "emits a trailing blank row after a single paragraph" do
      assert Markdown.render("hello", 80) == [
               [{"hello", nil}],
               [{"", nil}]
             ]
    end

    test "separates two paragraphs with a blank row each" do
      result = Markdown.render("first\n\nsecond", 80)

      assert result == [
               [{"first", nil}],
               [{"", nil}],
               [{"second", nil}],
               [{"", nil}]
             ]
    end
  end

  describe "render/3 with compact: true" do
    test "strips the trailing blank row after a single paragraph" do
      assert Markdown.render("hello", 80, compact: true) == [[{"hello", nil}]]
    end

    test "renders two paragraphs as adjacent rows with no separator" do
      result = Markdown.render("first\n\nsecond", 80, compact: true)

      assert result == [
               [{"first", nil}],
               [{"second", nil}]
             ]
    end

    test "preserves per-segment styling (only blank rows are stripped)" do
      result = Markdown.render("**bold** and *italic*", 80, compact: true)

      # Single paragraph row, no trailing blank, styling intact.
      assert [segments] = result

      assert Enum.any?(segments, fn
               {"bold", style} when not is_nil(style) -> true
               _ -> false
             end)
    end
  end

  describe "render/2 (back-compat shim)" do
    test "behaves like compact: false" do
      assert Markdown.render("hello", 80) == Markdown.render("hello", 80, [])
    end
  end

  describe "render/3 honors max_width for decorative borders" do
    test "HR fills the requested width" do
      [[{text, _style}] | _] = Markdown.render("---", 60, compact: true)
      assert String.length(text) == 60
    end

    test "HR does not exceed a narrow width" do
      [[{text, _style}] | _] = Markdown.render("---", 20, compact: true)
      assert String.length(text) == 20
    end

    test "fenced code block header + footer borders span the full width" do
      result = Markdown.render("```\ncode\n```", 40, compact: true)

      [header | rest] = result
      footer = List.last(rest)

      header_len = header |> Enum.map_join("", fn {t, _} -> t end) |> String.length()
      footer_len = footer |> Enum.map_join("", fn {t, _} -> t end) |> String.length()

      assert header_len == 40, "header was #{header_len}, expected 40 in #{inspect(header)}"
      assert footer_len == 40, "footer was #{footer_len}, expected 40 in #{inspect(footer)}"
    end
  end

  describe "render/3 tables" do
    test "renders a 2x2 table with box-draw borders" do
      table = """
      | A | B |
      |---|---|
      | 1 | 2 |
      """

      result = Markdown.render(table, 80, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # Expect top border, header row, separator, data row, bottom border.
      assert Enum.any?(lines, &(&1 =~ ~r/^┌─+┬─+┐$/u)), "no top border in #{inspect(lines)}"

      assert Enum.any?(lines, &(&1 =~ ~r/^│\s+A\s+│\s+B\s+│$/u)),
             "no header row in #{inspect(lines)}"

      assert Enum.any?(lines, &(&1 =~ ~r/^├─+┼─+┤$/u)), "no header sep in #{inspect(lines)}"

      assert Enum.any?(lines, &(&1 =~ ~r/^│\s+1\s+│\s+2\s+│$/u)),
             "no data row in #{inspect(lines)}"

      assert Enum.any?(lines, &(&1 =~ ~r/^└─+┴─+┘$/u)), "no bottom border in #{inspect(lines)}"
    end

    test "right-aligned column places content against the right edge" do
      table = """
      | Name | Age |
      |------|----:|
      | Ann  |  30 |
      """

      result = Markdown.render(table, 80, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # Header has right-aligned "Age", data has right-aligned "30".
      assert Enum.any?(lines, &(&1 =~ ~r/^│ Name │ Age │$/u))
      assert Enum.any?(lines, &(&1 =~ ~r/^│ Ann  │  30 │$/u))
    end

    test "falls back to plain text when the rendered table won't fit" do
      table = """
      | A | B |
      |---|---|
      | #{String.duplicate("x", 30)} | #{String.duplicate("y", 30)} |
      """

      # max_width=65 fits the plain row (63 chars) but not the box (67 chars).
      result = Markdown.render(table, 65, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # No box-draw glyphs anywhere -- this is the plain branch.
      refute Enum.any?(lines, &String.contains?(&1, "│"))
      refute Enum.any?(lines, &String.contains?(&1, "┌"))
      refute Enum.any?(lines, &String.contains?(&1, "┘"))

      # Cells joined by ' | ' (ASCII pipe), one row per source row.
      assert "A | B" in lines

      assert (String.duplicate("x", 30) <> " | " <> String.duplicate("y", 30)) in lines
    end
  end

  describe "render/3 syntax highlighting" do
    alias TermUI.Renderer.Style

    test "highlights elixir keywords (already supported)" do
      result = Markdown.render("```elixir\ndef foo, do: :ok\n```", 80, compact: true)
      flat = result |> Enum.flat_map(& &1) |> Enum.reject(fn {t, _} -> t == "" end)

      assert Enum.any?(flat, fn
               {"def", %Style{fg: :magenta}} -> true
               _ -> false
             end),
             "expected 'def' to be highlighted in #{inspect(flat)}"
    end

    test "highlights javascript keywords" do
      result = Markdown.render("```javascript\nconst x = 1;\n```", 80, compact: true)
      flat = result |> Enum.flat_map(& &1) |> Enum.reject(fn {t, _} -> t == "" end)

      assert Enum.any?(flat, fn
               {"const", %Style{}} -> true
               _ -> false
             end),
             "expected 'const' to be highlighted in #{inspect(flat)}"
    end

    test "highlights json keys" do
      result = Markdown.render("```json\n{\"a\": 1}\n```", 80, compact: true)
      flat = result |> Enum.flat_map(& &1) |> Enum.reject(fn {t, _} -> t == "" end)

      # JSON lexer should style strings; assert SOME segment carries a style
      # other than the default code-block yellow.
      assert Enum.any?(flat, fn
               {_, %Style{fg: fg}} when fg not in [nil, :yellow, :bright_black] -> true
               _ -> false
             end),
             "expected highlighted tokens in #{inspect(flat)}"
    end

    test "falls back to plain code for an unknown language" do
      result = Markdown.render("```ruby\nputs :hi\n```", 80, compact: true)
      flat = result |> Enum.flat_map(& &1) |> Enum.reject(fn {t, _} -> t == "" end)

      # All code-content segments stay in the default code_block style
      # (yellow fg). No surprise keyword colors leak in.
      code_segments = Enum.filter(flat, fn {t, _} -> String.contains?(t, "puts") end)

      assert Enum.all?(code_segments, fn
               {_, %Style{fg: :yellow}} -> true
               _ -> false
             end)
    end
  end

  describe "render/3 table edge cases" do
    test "renders inline styling inside table cells" do
      alias TermUI.Renderer.Style

      table = """
      | Name | Note |
      |------|------|
      | **bold** | `code` |
      """

      result = Markdown.render(table, 80, compact: true)
      flat = result |> Enum.flat_map(& &1)

      # Cell content should carry bold/code styling, not be flattened to plain text.
      assert Enum.any?(flat, fn
               {"bold", %Style{attrs: attrs}} -> :bold in attrs
               _ -> false
             end),
             "expected bold-styled segment in table cell, got #{inspect(flat)}"

      assert Enum.any?(flat, fn
               {"`code`", %Style{fg: :yellow}} -> true
               _ -> false
             end),
             "expected code-styled segment in table cell, got #{inspect(flat)}"
    end

    test "header-only table: no orphan separator above the bottom border" do
      table = """
      | A | B |
      |---|---|
      """

      result = Markdown.render(table, 80, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # Should be exactly top, header, bottom -- no `├─┼─┤` line.
      refute Enum.any?(lines, &(&1 =~ ~r/^├─+┼─+┤$/u)),
             "header-only table emitted an orphan separator: #{inspect(lines)}"

      assert Enum.any?(lines, &(&1 =~ ~r/^┌─+┬─+┐$/u))
      assert Enum.any?(lines, &(&1 =~ ~r/^└─+┴─+┘$/u))
    end

    test "tables emit a trailing blank row in default (non-compact) mode" do
      content = """
      | A | B |
      |---|---|
      | 1 | 2 |

      next
      """

      result = Markdown.render(content, 80)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # The line right before 'next' should be blank, matching the per-block
      # separation every other block emits.
      next_idx = Enum.find_index(lines, &(&1 == "next"))
      assert next_idx, "expected 'next' paragraph in #{inspect(lines)}"
      assert Enum.at(lines, next_idx - 1) == "", "no blank separator before 'next'"
    end

    test "CJK cell content aligns column widths by terminal columns, not graphemes" do
      table = """
      | Name | Age |
      |------|-----|
      | 日本語 | 30 |
      """

      result = Markdown.render(table, 80, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      data_row = Enum.find(lines, &String.contains?(&1, "日本語"))
      assert data_row, "data row missing in #{inspect(lines)}"

      # The terminal-width of "日本語" is 6 (3 chars × 2 columns), so the cell
      # should be padded to align with the 'Name' (4-column) header. The right
      # border should sit one ' ' past '語' (no extra trailing pad needed since
      # '日本語' is already wider than 'Name').
      assert String.contains?(data_row, "│ 日本語 │"),
             "CJK cell misaligned in #{inspect(data_row)}"
    end

    test "code-span cell drives column width by its rendered (backticked) form" do
      # Regression: column widths/padding were measured from the raw cell text
      # (without code-span backticks or link URL suffixes) while cells render
      # with them, so a code-heavy cell overflowed its column and shoved every
      # following border rightward. Every rendered line must share one width.
      table = """
      | Feature | Example |
      |---------|---------|
      | Short   | `a`     |
      | Long    | `:---`, `---:`, `:---:` |
      """

      result = Markdown.render(table, 80, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)
      box_lines = Enum.filter(lines, &String.contains?(&1, ["│", "┌", "├", "└"]))

      widths =
        box_lines
        |> Enum.map(&TermUI.Renderer.DisplayWidth.string_width/1)
        |> Enum.uniq()

      assert length(widths) == 1,
             "table rows have mismatched widths #{inspect(widths)}:\n#{Enum.join(box_lines, "\n")}"

      assert Enum.any?(box_lines, &String.contains?(&1, "`:---`, `---:`, `:---:`"))
    end
  end

  describe "render/3 nested blocks" do
    test "table nested inside a blockquote still renders rows and borders" do
      content = """
      > | A | B |
      > |---|---|
      > | 1 | 2 |
      """

      result = Markdown.render(content, 80, compact: true)
      flat = result |> Enum.flat_map(& &1) |> Enum.map_join("", fn {t, _} -> t end)

      # Box-draw chars must appear (table was rendered, not flattened to text).
      assert flat =~ "┌"
      assert flat =~ "│"
      assert flat =~ "└"
      # Cell content present.
      assert flat =~ "A"
      assert flat =~ "1"
    end

    test "code block nested in list inherits the panel width" do
      content = """
      - top:

          ```
          inner
          ```
      """

      # Render at 30: pre-fix, nested borders were hardcoded to 80 chars.
      result = Markdown.render(content, 30, compact: true)
      lines = Enum.map(result, fn segs -> Enum.map_join(segs, "", fn {t, _} -> t end) end)

      # No line should exceed max_width. Pre-fix, dash fills were 79+ wide
      # and would either overflow or get violently chopped by line wrapping.
      for line <- lines do
        assert String.length(line) <= 30,
               "line wider than max_width: #{inspect(line)} (#{String.length(line)} chars)"
      end

      # Borders and inner content actually present.
      full = Enum.join(lines, "\n")
      assert full =~ "┌"
      assert full =~ "└"
      assert full =~ "inner"
    end
  end

  describe "render_with_elements/3 with compact: true" do
    test "element start_line/end_line stay aligned with the compacted output" do
      content = """
      First paragraph.

      ```elixir
      def hello, do: :world
      ```

      After.
      """

      %{lines: lines, elements: [elem]} =
        Markdown.render_with_elements(content, 80, compact: true)

      # start_line must point at the actual code-block header in the compacted output.
      header_text =
        Enum.at(lines, elem.start_line)
        |> Enum.map_join("", fn {t, _} -> t end)

      assert String.starts_with?(header_text, "┌"),
             "start_line=#{elem.start_line} not on a header row; got #{inspect(header_text)}"

      # end_line must be within the compacted bounds.
      assert elem.end_line < length(lines),
             "end_line=#{elem.end_line} past content_height=#{length(lines)}"
    end
  end

  describe "render/3 input validation" do
    test "gfm: false disables strikethrough parsing" do
      # With GFM on (default), ~~text~~ produces a strikethrough run with no tildes.
      default = Markdown.render("~~gone~~", 80, compact: true)
      default_text = default |> Enum.flat_map(& &1) |> Enum.map_join("", fn {t, _} -> t end)
      refute default_text =~ "~~"

      # With gfm: false, the tildes survive as literal text.
      vanilla = Markdown.render("~~gone~~", 80, compact: true, gfm: false)
      vanilla_text = vanilla |> Enum.flat_map(& &1) |> Enum.map_join("", fn {t, _} -> t end)
      assert vanilla_text =~ "~~gone~~"
    end
  end

  describe "render/3 GFM extensions" do
    alias TermUI.Renderer.Style

    test "renders ~~text~~ with the :strikethrough attr" do
      [segments | _] = Markdown.render("~~gone~~", 80, compact: true)

      assert Enum.any?(segments, fn
               {"gone", %Style{attrs: attrs}} -> :strikethrough in attrs
               _ -> false
             end),
             "expected a {\"gone\", strikethrough style} in #{inspect(segments)}"
    end

    test "renders a checked task list item with [x] marker" do
      result = Markdown.render("- [x] done", 80, compact: true)

      flat = Enum.flat_map(result, & &1)
      text = Enum.map_join(flat, "", fn {t, _} -> t end)

      assert text =~ "[x]"
      assert text =~ "done"
    end

    test "renders an unchecked task list item with [ ] marker" do
      result = Markdown.render("- [ ] todo", 80, compact: true)

      flat = Enum.flat_map(result, & &1)
      text = Enum.map_join(flat, "", fn {t, _} -> t end)

      assert text =~ "[ ]"
      assert text =~ "todo"
    end
  end
end
