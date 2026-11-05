class_name L10nScreenProbe
extends RefCounted
## Collects the visible texts of a screen, in tree order, for the localization screen tests
## ([code]tests/test_l10n_screens.gd[/code], docs/localization.md section 12.2).
## [br][br]
## Each line is [code]<kind>\t<text>[/code], without node paths, so renaming nodes does not matter. Kinds:
## [code]label[/code], [code]button[/code], [code]tab[/code] (the title of every tab, visible or not),
## [code]option_item[/code], [code]placeholder[/code], [code]tooltip[/code], [code]rich[/code] (parsed text
## of a [RichTextLabel]) and [code]drawn[/code] (strings drawn with [code]UIFonts.draw_text[/code], passed
## by the caller). Nodes that are not visible in the tree and nodes marked with the metadata
## [code]l10n_raw[/code] (text written by players or staff) are skipped.

const RAW_META: StringName = &"l10n_raw"
const SEPARATOR: String = "\t"


## Lines for every visible text under [param root]; [param drawn] are appended as [code]drawn[/code] lines.
static func collect(root: Node, drawn: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var lines: PackedStringArray = PackedStringArray()
	_walk(root, lines)
	for text: String in drawn:
		lines.append("drawn" + SEPARATOR + text)
	return lines


## The texts to check against pseudolocalization: every line whose text has a letter or a digit.
static func texts_with_content(lines: PackedStringArray) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for line: String in lines:
		var text: String = line.get_slice(SEPARATOR, 1) if line.contains(SEPARATOR) else line
		if _has_letter_or_digit(text):
			result.append(line)
	return result


static func _has_letter_or_digit(text: String) -> bool:
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		var latin_letter: bool = code >= 192 and code <= 591 and code != 215 and code != 247
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) \
				or latin_letter:
			return true
	return false


static func _walk(node: Node, lines: PackedStringArray) -> void:
	if node is CanvasItem and not (node as CanvasItem).visible:
		return
	if node.has_meta(RAW_META):
		return
	if node is Control:
		_collect_control(node as Control, lines)
	for child: Node in node.get_children():
		_walk(child, lines)


static func _collect_control(control: Control, lines: PackedStringArray) -> void:
	if control is TabContainer:
		var tabs: TabContainer = control as TabContainer
		for index: int in tabs.get_tab_count():
			lines.append("tab" + SEPARATOR + tabs.get_tab_title(index))
	elif control is OptionButton:
		var option: OptionButton = control as OptionButton
		for index: int in option.item_count:
			lines.append("option_item" + SEPARATOR + option.get_item_text(index))
	elif control is Button:
		var text: String = (control as Button).text
		if not text.is_empty():
			lines.append("button" + SEPARATOR + text)
	elif control is Label:
		var text: String = (control as Label).text
		if not text.is_empty():
			lines.append("label" + SEPARATOR + text)
	elif control is RichTextLabel:
		var text: String = (control as RichTextLabel).get_parsed_text()
		if not text.is_empty():
			lines.append("rich" + SEPARATOR + text)
	elif control is LineEdit:
		var text: String = (control as LineEdit).placeholder_text
		if not text.is_empty():
			lines.append("placeholder" + SEPARATOR + text)
	if not control.tooltip_text.is_empty():
		lines.append("tooltip" + SEPARATOR + control.tooltip_text)
