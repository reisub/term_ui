defmodule TermUI.Renderer.DisplayWidth do
  @moduledoc """
  Calculates display width of Unicode characters and strings.

  Display width determines how many terminal columns a character occupies:
  - Most characters are single-width (1 column)
  - East Asian characters (CJK) are double-width (2 columns)
  - Combining characters are zero-width (0 columns)

  This module uses Unicode properties to determine width, essential for
  correct cursor positioning and layout calculations.
  """

  @doc """
  Returns the display width of a grapheme cluster.

  ## Examples

      iex> DisplayWidth.width("A")
      1

      iex> DisplayWidth.width("日")
      2

      iex> DisplayWidth.width("é")  # e + combining acute
      1
  """
  @spec width(String.t()) :: non_neg_integer()
  def width(grapheme) when is_binary(grapheme) do
    # A grapheme cluster's display width is NOT the sum of its codepoint
    # widths: paired regional indicators (🇺🇸 = two W codepoints), ZWJ
    # sequences (👨‍👩‍👧 = several W codepoints + ZWJ), skin-tone modifiers
    # (👨🏻 = base + Fitzpatrick) and keycap sequences (1️⃣ = digit + VS16 +
    # combining keycap) all render as a single 2-column glyph. Summing
    # codepoint widths would report 4, 6, 4, and 3 respectively. We instead
    # promote the whole cluster to width 2 if any codepoint is Wide or is
    # VS16 (which forces emoji presentation), and otherwise take the max
    # so combining-only clusters keep their zero width.
    grapheme
    |> String.to_charlist()
    |> Enum.reduce_while(0, fn
      0xFE0F, _ ->
        {:halt, 2}

      codepoint, max_acc ->
        case char_width(codepoint) do
          2 -> {:halt, 2}
          w -> {:cont, max(max_acc, w)}
        end
    end)
  end

  @doc """
  Returns the total display width of a string.

  ## Examples

      iex> DisplayWidth.string_width("Hello")
      5

      iex> DisplayWidth.string_width("日本語")
      6

      iex> DisplayWidth.string_width("Café")
      4
  """
  @spec string_width(String.t()) :: non_neg_integer()
  def string_width(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, acc ->
      acc + width(grapheme)
    end)
  end

  @doc """
  Checks if a character is double-width (East Asian Wide/Fullwidth).

  ## Examples

      iex> DisplayWidth.double_width?("日")
      true

      iex> DisplayWidth.double_width?("A")
      false
  """
  @spec double_width?(String.t()) :: boolean()
  def double_width?(grapheme) when is_binary(grapheme) do
    width(grapheme) == 2
  end

  @doc """
  Checks if a character is zero-width (combining character).

  ## Examples

      iex> DisplayWidth.zero_width?("\\u0301")  # combining acute
      true

      iex> DisplayWidth.zero_width?("A")
      false
  """
  @spec zero_width?(String.t()) :: boolean()
  def zero_width?(grapheme) when is_binary(grapheme) do
    width(grapheme) == 0
  end

  @doc """
  Truncates a string to fit within the given display width.

  Returns the truncated string and its actual display width.

  ## Examples

      iex> DisplayWidth.truncate("Hello World", 5)
      {"Hello", 5}

      iex> DisplayWidth.truncate("日本語", 4)
      {"日本", 4}
  """
  @spec truncate(String.t(), non_neg_integer()) :: {String.t(), non_neg_integer()}
  def truncate(string, max_width) when is_binary(string) and is_integer(max_width) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {chars, current_width} ->
      grapheme_width = width(grapheme)
      new_width = current_width + grapheme_width

      if new_width <= max_width do
        {:cont, {[grapheme | chars], new_width}}
      else
        {:halt, {chars, current_width}}
      end
    end)
    |> then(fn {chars, final_width} ->
      {chars |> Enum.reverse() |> Enum.join(), final_width}
    end)
  end

  @doc """
  Pads a string to the given display width.

  ## Options

  - `:direction` - `:left`, `:right`, or `:center` (default: `:right`)
  - `:char` - Padding character (default: " ")

  ## Examples

      iex> DisplayWidth.pad("Hi", 5)
      "Hi   "

      iex> DisplayWidth.pad("Hi", 5, direction: :left)
      "   Hi"

      iex> DisplayWidth.pad("日", 4)
      "日  "
  """
  @spec pad(String.t(), non_neg_integer(), keyword()) :: String.t()
  def pad(string, target_width, opts \\ []) when is_binary(string) and is_integer(target_width) do
    direction = Keyword.get(opts, :direction, :right)
    pad_char = Keyword.get(opts, :char, " ")

    current_width = string_width(string)
    padding_needed = max(0, target_width - current_width)

    case direction do
      :right ->
        string <> String.duplicate(pad_char, padding_needed)

      :left ->
        String.duplicate(pad_char, padding_needed) <> string

      :center ->
        left_pad = div(padding_needed, 2)
        right_pad = padding_needed - left_pad
        String.duplicate(pad_char, left_pad) <> string <> String.duplicate(pad_char, right_pad)
    end
  end

  # Private character width calculation
  #
  # Clause order matters: BEAM matches clauses sequentially, so the most
  # common codepoints (printable ASCII) MUST be matched first or every
  # character pays for traversing the entire wide-character table.

  # Printable ASCII fast-path — the dominant case for TUI text.
  defp char_width(c) when c >= 32 and c <= 126, do: 1

  # Control characters and NULL
  defp char_width(c) when c < 32, do: 0
  defp char_width(127), do: 0

  # DEL through 0x9F (C1 control characters)
  defp char_width(c) when c >= 0x7F and c <= 0x9F, do: 0

  # Combining characters (common ranges)
  # Combining Diacritical Marks
  defp char_width(c) when c >= 0x0300 and c <= 0x036F, do: 0
  # Combining Diacritical Marks Extended
  defp char_width(c) when c >= 0x1AB0 and c <= 0x1AFF, do: 0
  # Combining Diacritical Marks Supplement
  defp char_width(c) when c >= 0x1DC0 and c <= 0x1DFF, do: 0
  # Combining Diacritical Marks for Symbols
  defp char_width(c) when c >= 0x20D0 and c <= 0x20FF, do: 0
  # Combining Half Marks
  defp char_width(c) when c >= 0xFE20 and c <= 0xFE2F, do: 0

  # Zero-width characters
  # Zero Width Space, Non-Joiner, Joiner
  defp char_width(c) when c in [0x200B, 0x200C, 0x200D], do: 0
  # Word Joiner
  defp char_width(0x2060), do: 0
  # Zero Width No-Break Space (BOM)
  defp char_width(0xFEFF), do: 0

  # East Asian Wide / Fullwidth characters, per Unicode 15.1 EastAsianWidth.txt.
  # Ordered by codepoint for readability — the printable-ASCII clause above
  # is what keeps this table off the hot path.

  # Misc Technical: WATCH, HOURGLASS, angle brackets
  defp char_width(c) when c >= 0x231A and c <= 0x231B, do: 2
  defp char_width(c) when c >= 0x2329 and c <= 0x232A, do: 2
  # Misc Technical: media controls, alarm clock, hourglass with flowing sand
  defp char_width(c) when c >= 0x23E9 and c <= 0x23EC, do: 2
  defp char_width(0x23F0), do: 2
  defp char_width(0x23F3), do: 2
  # Geometric Shapes: medium small squares
  defp char_width(c) when c >= 0x25FD and c <= 0x25FE, do: 2
  # Misc Symbols: scattered Wide chars in 0x2600-0x26FF
  defp char_width(c) when c >= 0x2614 and c <= 0x2615, do: 2
  defp char_width(c) when c >= 0x2648 and c <= 0x2653, do: 2
  defp char_width(0x267F), do: 2
  defp char_width(0x2693), do: 2
  defp char_width(0x26A1), do: 2
  defp char_width(c) when c >= 0x26AA and c <= 0x26AB, do: 2
  defp char_width(c) when c >= 0x26BD and c <= 0x26BE, do: 2
  defp char_width(c) when c >= 0x26C4 and c <= 0x26C5, do: 2
  defp char_width(0x26CE), do: 2
  defp char_width(0x26D4), do: 2
  defp char_width(0x26EA), do: 2
  defp char_width(c) when c >= 0x26F2 and c <= 0x26F3, do: 2
  defp char_width(0x26F5), do: 2
  defp char_width(0x26FA), do: 2
  defp char_width(0x26FD), do: 2
  # Dingbats: scattered Wide chars in 0x2700-0x27BF (✅, ❌, ❗, ➡, etc.)
  defp char_width(0x2705), do: 2
  defp char_width(c) when c >= 0x270A and c <= 0x270B, do: 2
  defp char_width(0x2728), do: 2
  defp char_width(0x274C), do: 2
  defp char_width(0x274E), do: 2
  defp char_width(c) when c >= 0x2753 and c <= 0x2755, do: 2
  defp char_width(0x2757), do: 2
  defp char_width(c) when c >= 0x2795 and c <= 0x2797, do: 2
  defp char_width(0x27B0), do: 2
  defp char_width(0x27BF), do: 2
  # Misc Symbols and Arrows: large squares and stars
  defp char_width(c) when c >= 0x2B1B and c <= 0x2B1C, do: 2
  defp char_width(0x2B50), do: 2
  defp char_width(0x2B55), do: 2
  # CJK Radicals Supplement through Ideographic Description
  defp char_width(c) when c >= 0x2E80 and c <= 0x2FFF, do: 2
  # CJK Symbols and Punctuation, Hiragana, Katakana
  defp char_width(c) when c >= 0x3000 and c <= 0x303F, do: 2
  defp char_width(c) when c >= 0x3040 and c <= 0x309F, do: 2
  defp char_width(c) when c >= 0x30A0 and c <= 0x30FF, do: 2
  # Bopomofo through CJK Unified Ideographs Extension A
  defp char_width(c) when c >= 0x3100 and c <= 0x4DBF, do: 2
  # CJK Unified Ideographs
  defp char_width(c) when c >= 0x4E00 and c <= 0x9FFF, do: 2
  # Hangul Jamo
  defp char_width(c) when c >= 0x1100 and c <= 0x11FF, do: 2
  # Hangul Compatibility Jamo
  defp char_width(c) when c >= 0x3130 and c <= 0x318F, do: 2
  # Hangul Syllables
  defp char_width(c) when c >= 0xAC00 and c <= 0xD7AF, do: 2
  # CJK Compatibility Ideographs
  defp char_width(c) when c >= 0xF900 and c <= 0xFAFF, do: 2
  # Fullwidth Forms
  defp char_width(c) when c >= 0xFF01 and c <= 0xFF60, do: 2
  defp char_width(c) when c >= 0xFFE0 and c <= 0xFFE6, do: 2
  # Enclosed Alphanumeric / Ideographic Supplement (squared letters, parens CJK)
  defp char_width(0x1F004), do: 2
  defp char_width(0x1F0CF), do: 2
  defp char_width(0x1F18E), do: 2
  defp char_width(c) when c >= 0x1F191 and c <= 0x1F19A, do: 2
  defp char_width(c) when c >= 0x1F1E6 and c <= 0x1F1FF, do: 2
  # Enclosed Ideographic Supplement — only the W subranges; the rest of
  # 0x1F200..0x1F2FF is unassigned and would render as 1-col tofu.
  defp char_width(c) when c >= 0x1F200 and c <= 0x1F202, do: 2
  defp char_width(c) when c >= 0x1F210 and c <= 0x1F23B, do: 2
  defp char_width(c) when c >= 0x1F240 and c <= 0x1F248, do: 2
  defp char_width(c) when c >= 0x1F250 and c <= 0x1F251, do: 2
  defp char_width(c) when c >= 0x1F260 and c <= 0x1F265, do: 2
  # Miscellaneous Symbols and Pictographs, Emoticons, Transport, Supplemental
  defp char_width(c) when c >= 0x1F300 and c <= 0x1F64F, do: 2
  defp char_width(c) when c >= 0x1F680 and c <= 0x1F6FF, do: 2
  # Geometric Shapes Extended: colored circles and squares (🟡 🟢 🔴 🟦 etc.)
  defp char_width(c) when c >= 0x1F7E0 and c <= 0x1F7EB, do: 2
  defp char_width(0x1F7F0), do: 2
  defp char_width(c) when c >= 0x1F900 and c <= 0x1F9FF, do: 2
  # Symbols and Pictographs Extended-A (newer emoji added through Unicode 15.x)
  defp char_width(c) when c >= 0x1FA70 and c <= 0x1FAFF, do: 2
  # CJK Unified Ideographs Extension B-G and beyond
  defp char_width(c) when c >= 0x20000 and c <= 0x2FFFF, do: 2
  defp char_width(c) when c >= 0x30000 and c <= 0x3FFFF, do: 2

  # Default: single width
  defp char_width(_), do: 1
end
