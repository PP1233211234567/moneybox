extends SceneTree

const Decimal = preload("res://scripts/data/decimal_text.gd")

func _initialize() -> void:
	var cases := [
		[Decimal.canonical("00012.3400"), "12.34"],
		[Decimal.add("999999999999999999.99", "0.01"), "1000000000000000000"],
		[Decimal.subtract("0", "0.7"), "-0.7"],
		[Decimal.multiply("3110.34768", "7"), "21772.43376"],
		[Decimal.divide("21772.43376", "31.1034768"), "700"],
		[Decimal.divide("23700", "1000"), "23.7"],
		[Decimal.fixed("23.7", 12), "23.700000000000"],
		[Decimal.floor_nonnegative("23.7"), "23"],
	]
	for pair in cases:
		if pair[0] != pair[1]:
			printerr("decimal failed: ", pair[0], " expected ", pair[1])
			quit(1)
			return
	print("decimal: %d cases passed" % cases.size())
	quit(0)
