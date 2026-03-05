package main

import (
	"os"
	"strings"
	"testing"
)

// 需要 DASHSCOPE_API_KEY 环境变量，实际调用 API
func getAPIKey(t *testing.T) string {
	key := os.Getenv("DASHSCOPE_API_KEY")
	if key == "" {
		t.Skip("DASHSCOPE_API_KEY 未设置，跳过在线测试")
	}
	return key
}

func TestRefine_RemoveFillerWords(t *testing.T) {
	apiKey := getAPIKey(t)
	prompt := refinePrompts["both"]

	input := "嗯那个我觉得这个方案啊还是可以的就是需要再优化一下"
	result, err := callQwenRefine(apiKey, prompt, input)
	if err != nil {
		t.Fatalf("调用失败: %v", err)
	}

	t.Logf("输入: %s", input)
	t.Logf("输出: %s", result)

	// 口语词应被去除
	for _, filler := range []string{"嗯", "那个", "啊"} {
		if strings.Contains(result, filler) {
			t.Errorf("输出仍包含口语词 %q: %s", filler, result)
		}
	}
	// 应有标点
	if !strings.ContainsAny(result, "，。、；") {
		t.Error("输出缺少中文标点")
	}
}

func TestRefine_PreserveEnglish(t *testing.T) {
	apiKey := getAPIKey(t)
	prompt := refinePrompts["both"]

	input := "嗯这个API的response time太长了需要优化一下performance"
	result, err := callQwenRefine(apiKey, prompt, input)
	if err != nil {
		t.Fatalf("调用失败: %v", err)
	}

	t.Logf("输入: %s", input)
	t.Logf("输出: %s", result)

	// 英文必须保留
	for _, eng := range []string{"API", "response time", "performance"} {
		if !strings.Contains(result, eng) {
			t.Errorf("英文词 %q 被错误翻译或丢失: %s", eng, result)
		}
	}
}

func TestRefine_CorrectHomophones(t *testing.T) {
	apiKey := getAPIKey(t)
	prompt := refinePrompts["correct"]

	input := "我门今天在公司里讨论了一下这个放案"
	result, err := callQwenRefine(apiKey, prompt, input)
	if err != nil {
		t.Fatalf("调用失败: %v", err)
	}

	t.Logf("输入: %s", input)
	t.Logf("输出: %s", result)

	// 同音字应被修正
	if strings.Contains(result, "我门") {
		t.Error("同音字 '我门' 未修正为 '我们'")
	}
	if strings.Contains(result, "放案") {
		t.Error("同音字 '放案' 未修正为 '方案'")
	}
}

func TestRefine_NoExtraContent(t *testing.T) {
	apiKey := getAPIKey(t)
	prompt := refinePrompts["both"]

	input := "今天天气不错适合出去走走"
	result, err := callQwenRefine(apiKey, prompt, input)
	if err != nil {
		t.Fatalf("调用失败: %v", err)
	}

	t.Logf("输入: %s", input)
	t.Logf("输出: %s", result)

	// 不应添加解释性文字
	for _, extra := range []string{"修正", "优化", "以下是", "修改后"} {
		if strings.Contains(result, extra) {
			t.Errorf("输出包含多余解释 %q: %s", extra, result)
		}
	}
	// 输出长度不应远超输入（防止模型自由发挥）
	if len(result) > len(input)*3 {
		t.Errorf("输出过长（%d chars），可能包含多余内容: %s", len(result), result)
	}
}

func TestRefine_AllModes(t *testing.T) {
	apiKey := getAPIKey(t)

	input := "嗯那个我觉得这个bug应该是因为race condition导致的"

	for mode, prompt := range refinePrompts {
		t.Run(mode, func(t *testing.T) {
			result, err := callQwenRefine(apiKey, prompt, input)
			if err != nil {
				t.Fatalf("[%s] 调用失败: %v", mode, err)
			}
			t.Logf("[%s] 输入: %s", mode, input)
			t.Logf("[%s] 输出: %s", mode, result)

			if result == "" {
				t.Errorf("[%s] 返回空结果", mode)
			}
			// 英文术语应保留
			if !strings.Contains(result, "bug") || !strings.Contains(result, "race condition") {
				t.Errorf("[%s] 英文术语丢失: %s", mode, result)
			}
		})
	}
}
