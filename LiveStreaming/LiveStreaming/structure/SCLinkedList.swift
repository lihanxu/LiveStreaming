//
//  SCLinkedList.swift
//  DataStructure
//
//  Created by anker on 2021/6/27.
//

import Foundation

enum SCLinkedListError: Error {
    case outOfRange                     //越界
}

protocol SCList {
    associatedtype Element
    ///元素没有找到
    static var ELEMENT_NOT_FOUND: Int {get}
    ///链表长度
    func size() -> Int
    ///链表是否为空
    func isEmpty() -> Bool
    ///链表是否包含该元素
    func contains(element: Element) -> Bool
    ///添加元素链表尾部
    func add(element: Element)
    ///在at位置插入一个元素
    func add(element: Element, at index:Int)
    ///获取at位置的元素
    func get(at index: Int) -> Element
    ///覆盖at位置的元素
    func set(element: Element, at index:Int)
    ///获取该元素的位置
    func indexOf(element: Element) -> Int
    ///删除at位置的元素
    func remove(at index: Int)
    ///清空链表
    func clear()
}

class SCLinkedList<T: Equatable> {
    typealias Element = T
    
    //链表节点
    fileprivate class Node <Element> {
        ///节点中保存的元素
        var element: Element
        ///下一个节点
        var next: Node<Element>?
        
        init(element: Element, next:Node<Element>?) {
            self.element = element
            self.next = next
        }
    }
    
    fileprivate var listSize: Int = 0
    fileprivate var first: Node<Element>?
    
    fileprivate func rangeCheck(index: Int) throws {
        if index < 0 || index >= listSize {
            throw SCLinkedListError.outOfRange
        }
    }
    
    fileprivate func rangeCheckForAdd(index: Int) {
            do {
                if index < 0 || index > listSize {
                    throw SCLinkedListError.outOfRange
                }
            } catch {
                print("SCLinkedList:rangeCheckForAdd(:Int) error: SCLinkedListError.outOfRange")
            }
    }
    
    private func outOfBounds(index: Int) throws {
        throw SCLinkedListError.outOfRange
    }
    
    fileprivate func getNode(at: Int) -> Node<Element> {
        do {
            try rangeCheck(index: at)
        } catch {
            print("SCLinkedList:rangeCheck(:Int) error: \(error)")
        }
        var node = first
        for _ in 0..<at {
            node = node?.next
        }
        return node!
    }

    func printList() {
        var node = first
        for _ in 0..<listSize {
            print(node?.element ?? "")
            node = node?.next
        }
    }
}

extension SCLinkedList: SCList {
    
    static var ELEMENT_NOT_FOUND: Int {
        return -1
    }
    
    func size() -> Int {
        return listSize
    }
    
    func isEmpty() -> Bool {
        return listSize == 0
    }
    
    func contains(element: T) -> Bool {
        let index = indexOf(element: element)
        return (index != SCLinkedList<T>.ELEMENT_NOT_FOUND)
    }
    
    func add(element: T) {
        add(element: element, at: listSize)
    }
    
    func add(element: T, at index: Int) {
        rangeCheckForAdd(index: index)
        if index == 0 {
            first = Node(element: element, next: first)
        } else {
            let prev = getNode(at: index - 1)
            let node = Node(element: element, next: prev.next)
            prev.next = node
        }
        listSize += 1
    }
    
    func get(at index: Int) -> T {
        return getNode(at: index).element
    }
    
    func set(element: T, at index: Int) {
        let node = getNode(at: index)
        node.element = element
    }
    
    func indexOf(element: T) -> Int {
        var node = first
        for index in 0..<listSize {
            if node?.element == element {
                return index
            }
            node = node?.next
        }
        return SCLinkedList<T>.ELEMENT_NOT_FOUND
    }
    
    func remove(at index: Int) {
        do {
            try rangeCheck(index: index)
        } catch {
            print("SCLinkedList:rangeCheck(:Int) error: \(error)")
        }
        if index == 0 {
            first = first?.next
        } else {
            let prev = (index == 0) ? first : getNode(at: index - 1)
            let node = prev?.next
            prev?.next = node?.next
        }
        listSize -= 1
    }
    
    func clear() {
        listSize = 0
        first = nil
    }
}

extension SCLinkedList: CustomStringConvertible {
    var description: String {
        guard listSize > 0 else {
            return "nil"
        }
        var str = "\(first!.element)"
        var node = first?.next
        for _ in 0..<listSize - 1 {
            str += ", \( node!.element)"
            node = node?.next
        }
        return str
    }
}
