package main

// 热词表加载与运行时重载测试
//
// 测试范围：
//   - buildCorpusText: 解析热词文件格式（tab 分隔、注释跳过、音近提示）
//   - reloadHotwords: 运行时重载热词到内存
//   - findHotwordsFile: 文件查找优先级
//
// 不需要 API key，纯本地测试。
// 运行：cd asr-bridge && go test -v -run TestHotword

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestBuildCorpusText_Basic 基础格式解析
func TestBuildCorpusText_Basic(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")
	content := "Claude\t100\tzh\ten\n" +
		"Transformer\t80\tzh\ten\n" +
		"RAG\t90\tzh\ten\n"
	if err := os.WriteFile(f, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	result := buildCorpusText(f)
	if result == "" {
		t.Fatal("buildCorpusText returned empty")
	}
	for _, word := range []string{"Claude", "Transformer", "RAG"} {
		if !strings.Contains(result, word) {
			t.Errorf("corpus should contain %q", word)
		}
	}
}

// TestBuildCorpusText_WithPhoneticHint 包含音近提示（第5列）
func TestBuildCorpusText_WithPhoneticHint(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")
	content := "Claude\t100\tzh\ten\t克劳德\n" +
		"LLM\t80\tzh\ten\n"
	if err := os.WriteFile(f, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	result := buildCorpusText(f)
	if !strings.Contains(result, "Claude（克劳德）") {
		t.Errorf("should contain phonetic hint, got: %s", result)
	}
	if !strings.Contains(result, "LLM") {
		t.Error("should contain LLM without hint")
	}
}

// TestBuildCorpusText_SkipsComments 跳过注释和空行
func TestBuildCorpusText_SkipsComments(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")
	content := "# 这是注释\n\nClaude\t100\tzh\ten\n# 另一个注释\n\n"
	if err := os.WriteFile(f, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	result := buildCorpusText(f)
	if strings.Contains(result, "注释") {
		t.Error("should not contain comment text")
	}
	if !strings.Contains(result, "Claude") {
		t.Error("should contain Claude")
	}
}

// TestBuildCorpusText_EmptyFile 空文件返回空字符串
func TestBuildCorpusText_EmptyFile(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")
	if err := os.WriteFile(f, []byte("# only comments\n\n"), 0644); err != nil {
		t.Fatal(err)
	}

	result := buildCorpusText(f)
	if result != "" {
		t.Errorf("expected empty, got: %s", result)
	}
}

// TestBuildCorpusText_NonExistentFile 文件不存在返回空
func TestBuildCorpusText_NonExistentFile(t *testing.T) {
	result := buildCorpusText("/nonexistent/hotwords.txt")
	if result != "" {
		t.Errorf("expected empty for nonexistent file, got: %s", result)
	}
}

// TestReloadHotwords_UpdatesGlobal 验证 reload 更新全局变量
func TestReloadHotwords_UpdatesGlobal(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")

	// 初始内容
	if err := os.WriteFile(f, []byte("Alpha\t100\tzh\ten\n"), 0644); err != nil {
		t.Fatal(err)
	}

	// 模拟 initHotwords
	oldPath := hotwordsPath
	oldCorpus := qwen3Hotwords
	defer func() {
		hotwordsPath = oldPath
		qwen3Hotwords = oldCorpus
	}()

	hotwordsPath = f
	qwen3Hotwords = buildCorpusText(f)

	if !strings.Contains(qwen3Hotwords, "Alpha") {
		t.Fatal("initial load should contain Alpha")
	}

	// 更新文件内容
	if err := os.WriteFile(f, []byte("Alpha\t100\tzh\ten\nBeta\t80\tzh\ten\nGamma\t60\tzh\ten\n"), 0644); err != nil {
		t.Fatal(err)
	}

	// reload
	count, err := reloadHotwords()
	if err != nil {
		t.Fatalf("reloadHotwords failed: %v", err)
	}
	if count != 3 {
		t.Errorf("expected 3 words, got %d", count)
	}
	if !strings.Contains(qwen3Hotwords, "Beta") {
		t.Error("after reload should contain Beta")
	}
	if !strings.Contains(qwen3Hotwords, "Gamma") {
		t.Error("after reload should contain Gamma")
	}
}

// TestReloadHotwords_FileDeleted reload 时文件不可读，保留旧值并返回错误
func TestReloadHotwords_FileDeleted(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")

	oldPath := hotwordsPath
	oldCorpus := qwen3Hotwords
	defer func() {
		hotwordsPath = oldPath
		qwen3Hotwords = oldCorpus
	}()

	// 先创建再删除，模拟文件被删
	if err := os.WriteFile(f, []byte("Word\t100\tzh\ten\n"), 0644); err != nil {
		t.Fatal(err)
	}
	hotwordsPath = f
	qwen3Hotwords = buildCorpusText(f)
	savedCorpus := qwen3Hotwords

	os.Remove(f)

	// reload 应该返回错误，且保留旧 corpus
	_, err := reloadHotwords()
	if err == nil {
		t.Fatal("expected error when file not readable")
	}
	if qwen3Hotwords != savedCorpus {
		t.Errorf("corpus should be preserved on read failure, got: %s", qwen3Hotwords)
	}
}

// TestReloadHotwords_PreservesOldOnEmpty 文件变空时 corpus 也变空（不保留旧值）
func TestReloadHotwords_ClearsOnEmpty(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "hotwords.txt")

	oldPath := hotwordsPath
	oldCorpus := qwen3Hotwords
	defer func() {
		hotwordsPath = oldPath
		qwen3Hotwords = oldCorpus
	}()

	// 初始加载有内容
	if err := os.WriteFile(f, []byte("Word1\t100\tzh\ten\n"), 0644); err != nil {
		t.Fatal(err)
	}
	hotwordsPath = f
	qwen3Hotwords = buildCorpusText(f)

	// 文件变为只有注释
	if err := os.WriteFile(f, []byte("# empty\n"), 0644); err != nil {
		t.Fatal(err)
	}

	count, err := reloadHotwords()
	if err != nil {
		t.Fatalf("reloadHotwords failed: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 words, got %d", count)
	}
	if qwen3Hotwords != "" {
		t.Errorf("corpus should be empty, got: %s", qwen3Hotwords)
	}
}

// TestFindHotwordsFile_EnvOverride 环境变量优先级最高
func TestFindHotwordsFile_EnvOverride(t *testing.T) {
	tmp := t.TempDir()
	f := filepath.Join(tmp, "custom-hotwords.txt")
	if err := os.WriteFile(f, []byte("test\n"), 0644); err != nil {
		t.Fatal(err)
	}

	oldEnv := os.Getenv("HOTWORDS_FILE")
	os.Setenv("HOTWORDS_FILE", f)
	defer os.Setenv("HOTWORDS_FILE", oldEnv)

	result := findHotwordsFile()
	if result != f {
		t.Errorf("expected env override path %s, got %s", f, result)
	}
}
