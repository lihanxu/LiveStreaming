//
//  SCStack.swift
//  DataStructure
//
//  Created by anker on 2021/6/27.
//

import Foundation

class SCStack<T> {
    typealias Element = T
    private var list = Array<Element>()
    let semaphore: DispatchSemaphore?
    
    init(withSemaphore: Bool = false) {
        semaphore = withSemaphore ? DispatchSemaphore(value: 1) : nil
    }
    /// 栈的元素个数
    func size() -> Int {
        return list.count
    }
    
    /// 栈是否为空
    func isEmpty() -> Bool {
        return list.isEmpty
    }
    
    /// 添加一个元素到栈顶
    func push(element: Element) {
        semaphore?.wait()
        list.append(element)
        print(#function, size())
        semaphore?.signal()
    }
    
    /// 从栈顶弹出一个元素，并删除该元素
    func pop() -> Element? {
        semaphore?.wait()
        let ele = list.popLast()
        print(#function, size())
        semaphore?.signal()
        return ele
    }
    
    /// 查看栈顶元素
    func peak() -> Element? {
        semaphore?.wait()
        let ele = list.last
        print(#function, size())
        semaphore?.signal()
        return ele
    }
    
    /// 清除栈内所有元素
    func clear() {
        semaphore?.wait()
        list.removeAll()
        print(#function, size())
        semaphore?.signal()
    }
}
