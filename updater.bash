#!/bin/bash

# === Настройки ===
REPO_DIR="/root/hetzner-debian-installer/"  # Укажите путь к локальному репозиторию
BRANCH="main"                  # Ветка, за которой следить
GIT_REMOTE="origin"            # Удаленный репозиторий

# === Функция обновления репозитория ===
update_repo() {
    echo "[$(date)] Проверка обновлений в репозитории..."

    cd "$REPO_DIR" || { echo "Ошибка: не удалось зайти в $REPO_DIR"; exit 1; }

    git fetch "$GIT_REMOTE" "$BRANCH"

    LOCAL_COMMIT=$(git rev-parse HEAD)
    REMOTE_COMMIT=$(git rev-parse "$GIT_REMOTE/$BRANCH")

    if [ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]; then
        echo "Обнаружены изменения. Выполняем pull..."

        echo "Сброс локальных изменений..."
        git reset --hard "$GIT_REMOTE/$BRANCH"

        echo "Обновляем данные из удаленного репозитория..."
        git fetch --all
        git reset --hard "$GIT_REMOTE/$BRANCH"
        git pull --force "$GIT_REMOTE" "$BRANCH"

        echo "Обновление завершено."
        chmod -R +x `REPO_DIR`
    else
        echo "Нет новых изменений."
    fi
}

# === Основной цикл ===
while true; do
    update_repo
    sleep 30  # Проверять каждые 30 секунд (можно изменить)
done
