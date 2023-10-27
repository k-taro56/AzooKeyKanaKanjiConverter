//
//  afterCharacterAdded.swift
//  Keyboard
//
//  Created by ensan on 2020/09/14.
//  Copyright © 2020 ensan. All rights reserved.
//

import Foundation
import SwiftUtils

extension Kana2Kanji {
    /// カナを漢字に変換する関数, 最後の複数文字を追加した場合。
    /// - Parameters:
    ///   - inputData: 今のInputData。
    ///   - N_best: N_best。
    ///   - addedCount: 文字数
    ///   - previousResult: 追加される前のデータ。
    /// - Returns:
    ///   - 変換候補。
    /// ### 実装状況
    /// (0)多用する変数の宣言。
    ///
    /// (1)まず、追加された一文字に繋がるノードを列挙する。
    ///
    /// (2)次に、計算済みノードから、(1)で求めたノードにつながるようにregisterして、N_bestを求めていく。
    ///
    /// (3)(1)のregisterされた結果をresultノードに追加していく。この際EOSとの連接コストを計算しておく。
    ///
    /// (4)ノードをアップデートした上で返却する。
    func kana2lattice_added(_ inputData: ComposingText, N_best: Int, addedCount: Int, previousResult: (inputData: ComposingText, nodes: Nodes)) async throws -> (result: LatticeNode, nodes: Nodes) {
        debug("\(addedCount)文字追加。追加されたのは「\(inputData.input.suffix(addedCount))」")
        if addedCount == 1 {
            return try await kana2lattice_addedLast(inputData, N_best: N_best, previousResult: previousResult)
        }
        // (0)
        let count = inputData.input.count

        // (1)
        let addedNodes: [[LatticeNode]] = await self.dicdataStore.getAddedNodes(inputData: inputData, previousInputData: previousResult.inputData, count: count)

        // (2)
        for nodeArray in previousResult.nodes {
            try Task.checkCancellation()
            await Task.yield()
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if DicdataStore.shouldBeRemoved(data: node.data) {
                    continue
                }
                // 変換した文字数
                let nextIndex = node.inputRange.endIndex
                for nextnode in addedNodes[nextIndex] {
                    // この関数はこの時点で呼び出して、後のnode.registered.isEmptyで最終的に弾くのが良い。
                    if DicdataStore.shouldBeRemoved(data: nextnode.data) {
                        continue
                    }
                    // クラスの連続確率を計算する。
                    let ccValue: PValue = await self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                    // nodeの持っている全てのprevnodeに対して
                    for (index, value) in node.values.enumerated() {
                        let newValue: PValue = ccValue + value
                        // 追加すべきindexを取得する
                        let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                        if lastindex == N_best {
                            continue
                        }
                        let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                        // カウントがオーバーしている場合は除去する
                        if nextnode.prevs.count >= N_best {
                            nextnode.prevs.removeLast()
                        }
                        // removeしてからinsertした方が速い (insertはO(N)なので)
                        nextnode.prevs.insert(newnode, at: lastindex)
                    }
                }
            }
        }

        // (3)
        let result = LatticeNode.EOSNode

        for (i, nodeArray) in addedNodes.enumerated() {
            try Task.checkCancellation()
            await Task.yield()
            for node in nodeArray {
                if node.prevs.isEmpty {
                    continue
                }
                if DicdataStore.shouldBeRemoved(data: node.data) {
                    continue
                }
                // 生起確率を取得する。
                let wValue = node.data.value()
                if i == 0 {
                    // valuesを更新する
                    node.values = await self.dicdataStore.getCCValues(
                        queries: node.prevs.map {(
                            former: $0.data.rcid,
                            latter: node.data.lcid,
                            offset: $0.totalValue + wValue
                        )}
                    )
                } else {
                    // valuesを更新する
                    node.values = node.prevs.map {$0.totalValue + wValue}
                }
                // 変換した文字数
                let nextIndex = node.inputRange.endIndex
                if count == nextIndex {
                    // 最後に至るので
                    for index in node.prevs.indices {
                        let newnode = node.getRegisteredNode(index, value: node.values[index])
                        result.prevs.append(newnode)
                    }
                } else {
                    for nextnode in addedNodes[nextIndex] {
                        // この関数はこの時点で呼び出して、後のnode.registered.isEmptyで最終的に弾くのが良い。
                        if DicdataStore.shouldBeRemoved(data: nextnode.data) {
                            continue
                        }
                        // クラスの連続確率を計算する。
                        let ccValue: PValue = await self.dicdataStore.getCCValue(node.data.rcid, nextnode.data.lcid)
                        // nodeの持っている全てのprevnodeに対して
                        for (index, value) in node.values.enumerated() {
                            let newValue: PValue = ccValue + value
                            // 追加すべきindexを取得する
                            let lastindex: Int = (nextnode.prevs.lastIndex(where: {$0.totalValue >= newValue}) ?? -1) + 1
                            if lastindex == N_best {
                                continue
                            }
                            let newnode: RegisteredNode = node.getRegisteredNode(index, value: newValue)
                            // カウントがオーバーしている場合は除去する
                            if nextnode.prevs.count >= N_best {
                                nextnode.prevs.removeLast()
                            }
                            // removeしてからinsertした方が速い (insertはO(N)なので)
                            nextnode.prevs.insert(newnode, at: lastindex)
                        }
                    }
                }
            }
        }

        var nodes = previousResult.nodes
        for (index, nodeArray) in addedNodes.enumerated() {
            if index < nodes.endIndex {
                nodes[index].append(contentsOf: nodeArray)
            } else {
                nodes.append(nodeArray)
            }
        }
        return (result: result, nodes: nodes)
    }
}

private extension DicdataStore {
    func getAddedNodes(inputData: ComposingText, previousInputData: borrowing ComposingText, count: Int) -> [[LatticeNode]] {
        (.zero ..< count).map {(i: Int) in
            self.getLOUDSDataInRange(
                inputData: inputData,
                from: i,
                toIndexRange: (max(previousInputData.input.count, i) ..< max(previousInputData.input.count, min(count, i + self.maxlength + 1)))
            )
        }
    }
}
