#!/usr/bin/env bash
set -e

echo "========================================================"
echo "🚀 AI OPTIONS PRO - GITHUB AUTO-REPO & PUSH LAUNCHER"
echo "========================================================"

if ! command -v git &> /dev/null; then
  pkg install -y git
fi
if ! command -v curl &> /dev/null; then
  pkg install -y curl
fi

read -p "👤 Enter your GitHub Username: " GH_USER
read -s -p "🔑 Enter your GitHub Password / Personal Access Token (PAT): " GH_PASS
echo ""
read -p "📦 Enter Repository Name [default: ai-options-pro]: " REPO_NAME
REPO_NAME=${REPO_NAME:-ai-options-pro}

echo "⏳ Creating repository '$REPO_NAME' on GitHub (if not already present)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "$GH_USER:$GH_PASS" \
  -X POST https://api.github.com/user/repos \
  -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"auto_init\":false}")

if [ "$HTTP_CODE" = "201" ]; then
  echo "✅ Repository '$REPO_NAME' created automatically on GitHub!"
elif [ "$HTTP_CODE" = "422" ]; then
  echo "ℹ️ Repository '$REPO_NAME' already exists on your GitHub. Updating it..."
else
  echo "⚠️ GitHub API returned HTTP $HTTP_CODE (Verify your Personal Access Token has 'repo' & 'workflow' scope)."
fi

git init
git config user.name "$GH_USER"
git config user.email "$GH_USER@users.noreply.github.com"
git branch -M main
git add .
git commit -m "Deploy AI Options Pro: 1m Entry + HTF OI Confirm + Auto-TOTP + 5-Day Recalibration" || true

REMOTE_URL="https://${GH_USER}:${GH_PASS}@github.com/${GH_USER}/${REPO_NAME}.git"
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE_URL"

echo "⬆️ Pushing code & GitHub Actions APK workflow to GitHub..."
git push -u origin main --force

# Remove token from local git config after push for security
git remote set-url origin "https://github.com/${GH_USER}/${REPO_NAME}.git"

echo "========================================================"
echo "🎉 PUSH SUCCESSFUL!"
echo "👉 Open: https://github.com/${GH_USER}/${REPO_NAME}/actions"
echo "👉 Your standalone 'AI-Options-Pro-arm64-APK' is now building automatically!"
echo "========================================================"
