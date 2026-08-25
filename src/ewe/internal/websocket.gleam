pub type Message(user_message) {
  TextFrame(text: String)
  BinaryFrame(data: BitArray)
  UserMessage(message: user_message)
}
