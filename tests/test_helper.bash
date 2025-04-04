# Позволяет имитировать серию вводов через read
mock_read() {
    local inputs=("$@")
    local index=0
    read() {
        REPLY="${inputs[$index]}"
        index=$((index + 1))
    }
    export -f read
}
