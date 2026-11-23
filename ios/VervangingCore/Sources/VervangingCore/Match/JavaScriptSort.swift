import Foundation

// JavaScript's Array.prototype.sort as V8 runs it (Node 22): the TimSort in V8's third_party/v8/builtins/array-sort.tq,
// ported step for step. Extra minuten (public/js/match.js › extraOn) shuffles with `sort(() => random() - 0.5)`, a
// comparison that answers at random, so the order it gives depends on exactly which comparisons V8 makes and in what
// order. A plain Swift sort would make other comparisons, draw other random numbers and give another plan. This port
// makes the same calls in the same order and moves the elements the same way, so the same draws give the same order.
// Checked against Node 22 by JavaScriptSortTests.
//
// Source (third-party code, translated): third_party/v8/builtins/array-sort.tq in V8 at commit
// 8ab91836885699b9ef686c3a30df4778501ef7d1 (tag 12.4.254.21), blob 0b4e51226822f76eceb57e7f9dcc8b8d64286207:
// https://github.com/v8/v8/blob/8ab91836885699b9ef686c3a30df4778501ef7d1/third_party/v8/builtins/array-sort.tq
// Node 22.23.1 (V8 12.4.254.21-node.56, .node-version) ships the same blob in deps/v8.
// Copyright (c) 2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017,
// 2018 Python Software Foundation; All Rights Reserved
// Licence: the Python Software Foundation License Version 2 (V8 based the file on CPython's listobject.c), in
// third_party/v8/builtins/LICENSE, kept unchanged next to this file in JavaScriptSortLicense.swift.
// ⚠ PSF-2.0 is not in factory.yaml › licences.allow; this translation waits for the owner's approval (gate H2).
//
// Changes from the source (the summary the licence asks for): translated from Torque to Swift, by hand, with no line
// copied. Kept: the algorithm and the order of every comparison and element move (ArrayTimSortImpl,
// ComputeMinRunLength, CountAndMakeRun with ReverseRange, BinaryInsertionSort, MergeCollapse, MergeForceCollapse,
// MergeAt, GallopLeft, GallopRight, MergeLow, MergeHigh; kMinGallopWins 7 and the starting minGallop 7). Left out:
// what a plain Swift array does not need: element accessors and their bailouts, holes and undefined, the copy into and
// out of a work array, the default comparison without a comparator, the Smi overflow guard on gallop offsets and the
// result conversion of the comparator (here it returns a Double). Changed: generic over the element type, a new
// temporary array per merge instead of a reused one, and the Succeed and CopyA or CopyB labels as a MergeExit value.

/// V8's TimSort over `array`. `compare(a, b)` returns a number: below 0 when `a` comes before `b`. Like V8, every
/// comparison asks `compare`, even an inconsistent one, and the result is always a permutation of `array`.
func javaScriptSorted<T>(_ array: [T], by compare: @escaping (T, T) -> Double) -> [T] {
    var sorter = TimSort(work: array, compare: compare)
    sorter.sort()
    return sorter.work
}

/// How a merge ends: everything placed but the rest of the copied run, or the one element left in the copied run goes
/// after (MergeLow) or before (MergeHigh) the rest of the other run: V8's Succeed and CopyB or CopyA labels.
private enum MergeExit { case succeed, copyRest }

private struct TimSort<T> {
    var work: [T]
    let compare: (T, T) -> Double
    var minGallop = 7
    var runs: [(base: Int, length: Int)] = []
    static var minGallopWins: Int { 7 }

    init(work: [T], compare: @escaping (T, T) -> Double) {
        self.work = work
        self.compare = compare
    }

    func less(_ a: T, _ b: T) -> Bool { compare(a, b) < 0 }

    mutating func sort() {
        let length = work.count
        if length < 2 { return }
        var remaining = length
        var low = 0
        let minRun = TimSort.minRunLength(remaining)
        while remaining != 0 {
            var run = countAndMakeRun(low, low + remaining)
            if run < minRun {
                let forced = min(minRun, remaining)
                binaryInsertionSort(low, low + run, low + forced)
                run = forced
            }
            runs.append((low, run))
            mergeCollapse()
            low += run
            remaining -= run
        }
        mergeForceCollapse()
    }

    static func minRunLength(_ nArg: Int) -> Int {
        var n = nArg
        var r = 0
        while n >= 64 {
            r |= n & 1
            n >>= 1
        }
        return n + r
    }

    mutating func binaryInsertionSort(_ low: Int, _ startArg: Int, _ high: Int) {
        var start = low == startArg ? startArg + 1 : startArg
        while start < high {
            var left = low
            var right = start
            let pivot = work[start]
            while left < right {
                let mid = left + ((right - left) >> 1)
                if less(pivot, work[mid]) { right = mid } else { left = mid + 1 }
            }
            var p = start
            while p > left {
                work[p] = work[p - 1]
                p -= 1
            }
            work[left] = pivot
            start += 1
        }
    }

    mutating func countAndMakeRun(_ low: Int, _ high: Int) -> Int {
        if low + 1 == high { return 1 }
        var runLength = 2
        let elementLowPlusOne = work[low + 1]
        let isDescending = less(elementLowPlusOne, work[low])
        var previous = elementLowPlusOne
        var idx = low + 2
        while idx < high {
            let current = work[idx]
            let order = less(current, previous)
            if isDescending ? !order : order { break }
            previous = current
            runLength += 1
            idx += 1
        }
        if isDescending {
            var a = low, b = low + runLength - 1
            while a < b {
                work.swapAt(a, b)
                a += 1
                b -= 1
            }
        }
        return runLength
    }

    func invariantHolds(_ n: Int) -> Bool {
        if n < 2 { return true }
        return runs[n - 2].length > runs[n - 1].length + runs[n].length
    }

    mutating func mergeCollapse() {
        while runs.count > 1 {
            var n = runs.count - 2
            if !invariantHolds(n + 1) || !invariantHolds(n) {
                if runs[n - 1].length < runs[n + 1].length { n -= 1 }
                mergeAt(n)
            } else if runs[n].length <= runs[n + 1].length {
                mergeAt(n)
            } else {
                break
            }
        }
    }

    mutating func mergeForceCollapse() {
        while runs.count > 1 {
            var n = runs.count - 2
            if n > 0 && runs[n - 1].length < runs[n + 1].length { n -= 1 }
            mergeAt(n)
        }
    }

    mutating func mergeAt(_ i: Int) {
        var baseA = runs[i].base, lengthA = runs[i].length
        let baseB = runs[i + 1].base
        var lengthB = runs[i + 1].length
        runs[i].length = lengthA + lengthB
        runs.remove(at: i + 1)
        let k = gallopRight(work, key: work[baseB], base: baseA, length: lengthA, hint: 0)
        baseA += k
        lengthA -= k
        if lengthA == 0 { return }
        lengthB = gallopLeft(work, key: work[baseA + lengthA - 1], base: baseB, length: lengthB, hint: lengthB - 1)
        if lengthB == 0 { return }
        if lengthA <= lengthB {
            mergeLow(baseA, lengthA, baseB, lengthB)
        } else {
            mergeHigh(baseA, lengthA, baseB, lengthB)
        }
    }

    /// Where `key` goes in the sorted `array[base..<base+length]`: before the leftmost equal element.
    func gallopLeft(_ array: [T], key: T, base: Int, length: Int, hint: Int) -> Int {
        var lastOfs = 0
        var offset = 1
        if less(array[base + hint], key) {
            let maxOfs = length - hint
            while offset < maxOfs {
                if !less(array[base + hint + offset], key) { break }
                lastOfs = offset
                offset = (offset << 1) + 1
            }
            if offset > maxOfs { offset = maxOfs }
            lastOfs += hint
            offset += hint
        } else {
            let maxOfs = hint + 1
            while offset < maxOfs {
                if less(array[base + hint - offset], key) { break }
                lastOfs = offset
                offset = (offset << 1) + 1
            }
            if offset > maxOfs { offset = maxOfs }
            let tmp = lastOfs
            lastOfs = hint - offset
            offset = hint - tmp
        }
        lastOfs += 1
        while lastOfs < offset {
            let m = lastOfs + ((offset - lastOfs) >> 1)
            if less(array[base + m], key) { lastOfs = m + 1 } else { offset = m }
        }
        return offset
    }

    /// Where `key` goes in the sorted `array[base..<base+length]`: after the rightmost equal element.
    func gallopRight(_ array: [T], key: T, base: Int, length: Int, hint: Int) -> Int {
        var lastOfs = 0
        var offset = 1
        if less(key, array[base + hint]) {
            let maxOfs = hint + 1
            while offset < maxOfs {
                if !less(key, array[base + hint - offset]) { break }
                lastOfs = offset
                offset = (offset << 1) + 1
            }
            if offset > maxOfs { offset = maxOfs }
            let tmp = lastOfs
            lastOfs = hint - offset
            offset = hint - tmp
        } else {
            let maxOfs = length - hint
            while offset < maxOfs {
                if less(key, array[base + hint + offset]) { break }
                lastOfs = offset
                offset = (offset << 1) + 1
            }
            if offset > maxOfs { offset = maxOfs }
            lastOfs += hint
            offset += hint
        }
        lastOfs += 1
        while lastOfs < offset {
            let m = lastOfs + ((offset - lastOfs) >> 1)
            if less(key, array[base + m]) { offset = m } else { lastOfs = m + 1 }
        }
        return offset
    }

    mutating func mergeLow(_ baseA: Int, _ lengthAArg: Int, _ baseB: Int, _ lengthBArg: Int) {
        var lengthA = lengthAArg, lengthB = lengthBArg
        let temp = Array(work[baseA..<(baseA + lengthA)])
        var dest = baseA, cursorTemp = 0, cursorB = baseB
        func run() -> MergeExit {
            work[dest] = work[cursorB]; dest += 1; cursorB += 1
            lengthB -= 1
            if lengthB == 0 { return .succeed }
            if lengthA == 1 { return .copyRest }
            var gallop = minGallop
            while true {
                var winsA = 0, winsB = 0
                while true {
                    if less(work[cursorB], temp[cursorTemp]) {
                        work[dest] = work[cursorB]; dest += 1; cursorB += 1
                        winsB += 1; lengthB -= 1; winsA = 0
                        if lengthB == 0 { return .succeed }
                        if winsB >= gallop { break }
                    } else {
                        work[dest] = temp[cursorTemp]; dest += 1; cursorTemp += 1
                        winsA += 1; lengthA -= 1; winsB = 0
                        if lengthA == 1 { return .copyRest }
                        if winsA >= gallop { break }
                    }
                }
                gallop += 1
                var first = true
                while winsA >= TimSort.minGallopWins || winsB >= TimSort.minGallopWins || first {
                    first = false
                    gallop = max(1, gallop - 1)
                    minGallop = gallop
                    winsA = gallopRight(temp, key: work[cursorB], base: cursorTemp, length: lengthA, hint: 0)
                    if winsA > 0 {
                        for i in 0..<winsA { work[dest + i] = temp[cursorTemp + i] }
                        dest += winsA; cursorTemp += winsA; lengthA -= winsA
                        if lengthA == 1 { return .copyRest }
                        if lengthA == 0 { return .succeed }
                    }
                    work[dest] = work[cursorB]; dest += 1; cursorB += 1
                    lengthB -= 1
                    if lengthB == 0 { return .succeed }
                    winsB = gallopLeft(work, key: temp[cursorTemp], base: cursorB, length: lengthB, hint: 0)
                    if winsB > 0 {
                        for i in 0..<winsB { work[dest + i] = work[cursorB + i] }
                        dest += winsB; cursorB += winsB; lengthB -= winsB
                        if lengthB == 0 { return .succeed }
                    }
                    work[dest] = temp[cursorTemp]; dest += 1; cursorTemp += 1
                    lengthA -= 1
                    if lengthA == 1 { return .copyRest }
                }
                gallop += 1
                minGallop = gallop
            }
        }
        switch run() {
        case .succeed:
            for i in 0..<max(0, lengthA) { work[dest + i] = temp[cursorTemp + i] }
        case .copyRest:
            for i in 0..<lengthB { work[dest + i] = work[cursorB + i] }
            work[dest + lengthB] = temp[cursorTemp]
        }
    }

    mutating func mergeHigh(_ baseA: Int, _ lengthAArg: Int, _ baseB: Int, _ lengthBArg: Int) {
        var lengthA = lengthAArg, lengthB = lengthBArg
        let temp = Array(work[baseB..<(baseB + lengthB)])
        var dest = baseB + lengthB - 1, cursorTemp = lengthB - 1, cursorA = baseA + lengthA - 1
        func run() -> MergeExit {
            work[dest] = work[cursorA]; dest -= 1; cursorA -= 1
            lengthA -= 1
            if lengthA == 0 { return .succeed }
            if lengthB == 1 { return .copyRest }
            var gallop = minGallop
            while true {
                var winsA = 0, winsB = 0
                while true {
                    if less(temp[cursorTemp], work[cursorA]) {
                        work[dest] = work[cursorA]; dest -= 1; cursorA -= 1
                        winsA += 1; lengthA -= 1; winsB = 0
                        if lengthA == 0 { return .succeed }
                        if winsA >= gallop { break }
                    } else {
                        work[dest] = temp[cursorTemp]; dest -= 1; cursorTemp -= 1
                        winsB += 1; lengthB -= 1; winsA = 0
                        if lengthB == 1 { return .copyRest }
                        if winsB >= gallop { break }
                    }
                }
                gallop += 1
                var first = true
                while winsA >= TimSort.minGallopWins || winsB >= TimSort.minGallopWins || first {
                    first = false
                    gallop = max(1, gallop - 1)
                    minGallop = gallop
                    var k = gallopRight(work, key: temp[cursorTemp], base: baseA, length: lengthA, hint: lengthA - 1)
                    winsA = lengthA - k
                    if winsA > 0 {
                        dest -= winsA; cursorA -= winsA
                        for i in stride(from: winsA - 1, through: 0, by: -1) { work[dest + 1 + i] = work[cursorA + 1 + i] }
                        lengthA -= winsA
                        if lengthA == 0 { return .succeed }
                    }
                    work[dest] = temp[cursorTemp]; dest -= 1; cursorTemp -= 1
                    lengthB -= 1
                    if lengthB == 1 { return .copyRest }
                    k = gallopLeft(temp, key: work[cursorA], base: 0, length: lengthB, hint: lengthB - 1)
                    winsB = lengthB - k
                    if winsB > 0 {
                        dest -= winsB; cursorTemp -= winsB
                        for i in 0..<winsB { work[dest + 1 + i] = temp[cursorTemp + 1 + i] }
                        lengthB -= winsB
                        if lengthB == 1 { return .copyRest }
                        if lengthB == 0 { return .succeed }
                    }
                    work[dest] = work[cursorA]; dest -= 1; cursorA -= 1
                    lengthA -= 1
                    if lengthA == 0 { return .succeed }
                }
                gallop += 1
                minGallop = gallop
            }
        }
        switch run() {
        case .succeed:
            if lengthB > 0 { for i in 0..<lengthB { work[dest - (lengthB - 1) + i] = temp[i] } }
        case .copyRest:
            dest -= lengthA; cursorA -= lengthA
            for i in stride(from: lengthA - 1, through: 0, by: -1) { work[dest + 1 + i] = work[cursorA + 1 + i] }
            work[dest] = temp[cursorTemp]
        }
    }
}
