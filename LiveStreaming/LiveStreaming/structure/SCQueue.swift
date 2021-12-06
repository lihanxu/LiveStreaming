//
//  SCQueue.swift
//  DataStructure
//
//  Created by anker on 2021/6/27.
//

import Foundation

class SCQueue<T> {
    typealias Element = T
    private var list = Array<T>()
    private let semaphore: DispatchSemaphore?
    
    init(withSemaphore: Bool = false) {
        semaphore = withSemaphore ? DispatchSemaphore(value: 1) : nil
    }

    /// 队列的元素个数
    func size() -> Int {
        return list.count
    }
    
    /// 队列是否为空
    func isEmpty() -> Bool {
        return list.isEmpty
    }
    
    /// 添加一个元素到队尾
    func enqueue(element: Element) {
        semaphore?.wait()
        print(#function, size())
        list.append(element)
        semaphore?.signal()
    }
    
    /// 获取队头元素，并删除该元素
    func dequeue() -> Element? {
        semaphore?.wait()
        print(#function, size())
        guard isEmpty() == false else {
            semaphore?.signal()
            return nil
        }
        let ele = list.remove(at: 0)
        semaphore?.signal()
        return ele
    }
    
    /// 获取队头元素，该元素不会被删除
    func peak() -> Element? {
        semaphore?.wait()
        print(#function, size())
        guard isEmpty() == false else {
            semaphore?.signal()
            return nil
        }
        let ele = list[0]
        semaphore?.signal()
        return ele
    }
    
    /// 清除队列所有元素
    func clear() {
        semaphore?.wait()
        list.removeAll()
        semaphore?.signal()
    }
}
