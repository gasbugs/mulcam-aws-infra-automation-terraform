package com.example.demo;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

// 스프링 컨텍스트 없이 순수 Java 로직만 검증하는 단위 테스트
class DemoApplicationTest {

    // hello() 메서드가 올바른 문자열을 반환하는지 확인
    @Test
    void hello_returnsExpectedMessage() {
        DemoApplication app = new DemoApplication();
        String result = app.hello();
        assertEquals("Hello from Spring Boot! - Packer Image", result);
    }
}
