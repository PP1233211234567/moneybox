extends RefCounted
## Decimal arithmetic on canonical base-10 strings. No financial value passes through float.

static func canonical(value: String) -> String:
	if value.is_empty():
		return ""
	var negative := value.begins_with("-")
	var start := 1 if negative else 0
	if start == value.length():
		return ""
	var dot_seen := false
	var whole := ""
	var fraction := ""
	for index in range(start, value.length()):
		var character := value.substr(index, 1)
		if character == "." and not dot_seen:
			dot_seen = true
			continue
		if character < "0" or character > "9":
			return ""
		if dot_seen:
			fraction += character
		else:
			whole += character
	if whole.is_empty() or (dot_seen and fraction.is_empty()):
		return ""
	whole = _strip_zeros(whole)
	while fraction.ends_with("0"):
		fraction = fraction.substr(0, fraction.length() - 1)
	var result := whole
	if not fraction.is_empty():
		result += "." + fraction
	if negative and result != "0":
		result = "-" + result
	return result


static func is_valid(value: String) -> bool:
	return not canonical(value).is_empty()


static func compare(left: String, right: String) -> int:
	var a := _parts(left)
	var b := _parts(right)
	if a.is_empty() or b.is_empty():
		return 0
	if a.sign != b.sign:
		return -1 if a.sign < b.sign else 1
	var scale: int = maxi(a.scale, b.scale)
	var cmp := _compare_unsigned(a.digits + "0".repeat(scale - a.scale), b.digits + "0".repeat(scale - b.scale))
	return cmp * a.sign


static func add(left: String, right: String) -> String:
	var a := _parts(left)
	var b := _parts(right)
	if a.is_empty() or b.is_empty():
		return ""
	var scale: int = maxi(a.scale, b.scale)
	var ad: String = a.digits + "0".repeat(scale - a.scale)
	var bd: String = b.digits + "0".repeat(scale - b.scale)
	if a.sign == b.sign:
		return _from_parts(_add_unsigned(ad, bd), scale, a.sign)
	var cmp := _compare_unsigned(ad, bd)
	if cmp == 0:
		return "0"
	if cmp > 0:
		return _from_parts(_subtract_unsigned(ad, bd), scale, a.sign)
	return _from_parts(_subtract_unsigned(bd, ad), scale, b.sign)


static func subtract(left: String, right: String) -> String:
	var value := canonical(right)
	if value.is_empty():
		return ""
	return add(left, value.substr(1) if value.begins_with("-") else "-" + value)


static func multiply(left: String, right: String) -> String:
	var a := _parts(left)
	var b := _parts(right)
	if a.is_empty() or b.is_empty():
		return ""
	var total: Array[int] = []
	total.resize(a.digits.length() + b.digits.length())
	total.fill(0)
	for i in range(a.digits.length() - 1, -1, -1):
		for j in range(b.digits.length() - 1, -1, -1):
			var location := i + j + 1
			var product: int = (a.digits.unicode_at(i) - 48) * (b.digits.unicode_at(j) - 48) + total[location]
			total[location] = product % 10
			total[location - 1] += product / 10
	var digits := ""
	for digit in total:
		digits += str(digit)
	return _from_parts(digits, a.scale + b.scale, a.sign * b.sign)


static func divide(left: String, right: String, precision: int = 12) -> String:
	var a := _parts(left)
	var b := _parts(right)
	if a.is_empty() or b.is_empty() or b.digits == "0" or precision < 0 or precision > 30:
		return ""
	var numerator: String = a.digits + "0".repeat(b.scale + precision)
	var denominator: String = b.digits + "0".repeat(a.scale)
	var result := _divide_unsigned(numerator, denominator)
	var quotient: String = result.quotient
	var twice_remainder := _add_unsigned(result.remainder, result.remainder)
	var cmp := _compare_unsigned(twice_remainder, denominator)
	if cmp > 0 or (cmp == 0 and ((quotient.unicode_at(quotient.length() - 1) - 48) % 2 == 1)):
		quotient = _add_unsigned(quotient, "1")
	return _from_parts(quotient, precision, a.sign * b.sign)


static func floor_nonnegative(value: String) -> String:
	var normalized := canonical(value)
	if normalized.is_empty() or normalized.begins_with("-"):
		return ""
	return normalized.get_slice(".", 0)


static func fixed(value: String, scale: int) -> String:
	if scale < 0 or scale > 30:
		return ""
	var rounded := divide(value, "1", scale)
	if rounded.is_empty():
		return ""
	if scale == 0:
		return rounded
	var pieces := rounded.split(".")
	return pieces[0] + "." + (pieces[1] if pieces.size() > 1 else "").rpad(scale, "0")


static func _parts(value: String) -> Dictionary:
	var normalized := canonical(value)
	if normalized.is_empty():
		return {}
	var sign := -1 if normalized.begins_with("-") else 1
	if sign < 0:
		normalized = normalized.substr(1)
	var pieces := normalized.split(".")
	return {"sign": sign, "digits": _strip_zeros(pieces[0] + (pieces[1] if pieces.size() > 1 else "")), "scale": pieces[1].length() if pieces.size() > 1 else 0}


static func _from_parts(digits: String, scale: int, sign: int) -> String:
	digits = _strip_zeros(digits)
	if digits == "0":
		return "0"
	if scale > 0:
		if digits.length() <= scale:
			digits = "0".repeat(scale + 1 - digits.length()) + digits
		digits = digits.insert(digits.length() - scale, ".")
	return canonical(("-" if sign < 0 else "") + digits)


static func _strip_zeros(digits: String) -> String:
	var index := 0
	while index < digits.length() - 1 and digits.substr(index, 1) == "0":
		index += 1
	return digits.substr(index)


static func _compare_unsigned(left: String, right: String) -> int:
	var a := _strip_zeros(left)
	var b := _strip_zeros(right)
	if a.length() != b.length():
		return -1 if a.length() < b.length() else 1
	if a == b:
		return 0
	return -1 if a < b else 1


static func _add_unsigned(left: String, right: String) -> String:
	var carry := 0
	var output := ""
	var i := left.length() - 1
	var j := right.length() - 1
	while i >= 0 or j >= 0 or carry > 0:
		var digit := carry
		if i >= 0:
			digit += left.unicode_at(i) - 48
			i -= 1
		if j >= 0:
			digit += right.unicode_at(j) - 48
			j -= 1
		output = str(digit % 10) + output
		carry = digit / 10
	return _strip_zeros(output)


static func _subtract_unsigned(left: String, right: String) -> String:
	var borrow := 0
	var output := ""
	var j := right.length() - 1
	for i in range(left.length() - 1, -1, -1):
		var digit := left.unicode_at(i) - 48 - borrow
		if j >= 0:
			digit -= right.unicode_at(j) - 48
			j -= 1
		borrow = 1 if digit < 0 else 0
		if borrow:
			digit += 10
		output = str(digit) + output
	return _strip_zeros(output)


static func _divide_unsigned(numerator: String, denominator: String) -> Dictionary:
	var remainder := "0"
	var quotient := ""
	for i in numerator.length():
		remainder = _strip_zeros(remainder + numerator.substr(i, 1))
		var digit := 0
		while _compare_unsigned(remainder, denominator) >= 0:
			remainder = _subtract_unsigned(remainder, denominator)
			digit += 1
		quotient += str(digit)
	return {"quotient": _strip_zeros(quotient), "remainder": remainder}
